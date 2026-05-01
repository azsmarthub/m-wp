#!/usr/bin/env bash
# lib/multi-app.sh — App lifecycle (Docker-backed apps, Phase 5a image-mode)
#
# Public:
#   app_create <name> --domain D --image IMG --port P [--memory M] [--env K=V]... [--volume H:C]... [--env-file F]
#   app_delete <name>
#   app_start  <name>
#   app_stop   <name>
#   app_restart <name>
#   app_logs   <name> [-f] [-n N]
#   app_exec   <name> -- <cmd>
#   app_shell  <name>
#   app_nginx_enable_https <name> <domain> <cert_dir>   (called by ssl flow)

[[ -n "${_MWP_APP_LOADED:-}" ]] && return 0
_MWP_APP_LOADED=1

# Lazy-load deps
_app_deps_loaded=0
_load_app_deps() {
    [[ $_app_deps_loaded -eq 1 ]] && return
    source "$MWP_DIR/lib/multi-docker.sh"
    source "$MWP_DIR/lib/app-registry.sh"
    source "$MWP_DIR/lib/multi-nginx.sh"
    _app_deps_loaded=1
}

# ---------------------------------------------------------------------------
# app_create — main entry. Args parsed positionally + --flags.
# ---------------------------------------------------------------------------
app_create() {
    require_root
    _load_app_deps
    docker_engine_check

    local name="${1:-}"
    [[ -z "$name" ]] && die "Usage: mwp app create <name> --domain D --image IMG --port P [options]"
    shift

    local domain="" image="" internal_port="" memory_limit=""
    local env_args=() volume_args=()
    local env_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)    domain="$2"; shift 2 ;;
            --image)     image="$2"; shift 2 ;;
            --port)      internal_port="$2"; shift 2 ;;
            --memory)    memory_limit="$2"; shift 2 ;;
            --env)       env_args+=( -e "$2" ); shift 2 ;;
            --env-file)  env_file="$2"; shift 2 ;;
            --volume|-v) volume_args+=( -v "$2" ); shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    # --- Validate ---
    validate_app_name "$name" || \
        die "Invalid app name '$name'. Must be 1-32 chars, lowercase letters/digits/dashes, start with a letter."
    [[ -z "$domain" ]] && die "Required: --domain <domain>"
    [[ -z "$image" ]]  && die "Required: --image <image:tag>"
    validate_domain "$domain" || die "Invalid domain: $domain"

    app_exists "$name" && die "App '$name' already exists. Run: mwp app info $name"
    site_exists "$domain" && die "Domain '$domain' is already used by a WordPress site."

    local existing_app
    existing_app="$(app_find_by_domain "$domain" 2>/dev/null || true)"
    [[ -n "$existing_app" ]] && die "Domain '$domain' is already used by app '$existing_app'."

    nginx_check_setup

    # Default port if not specified — most Node/Next/n8n apps use 3000.
    internal_port="${internal_port:-3000}"
    [[ "$internal_port" =~ ^[0-9]+$ ]] || die "Invalid --port: must be a number"

    # Validate env-file early (docker would fail later otherwise)
    if [[ -n "$env_file" ]]; then
        [[ -f "$env_file" ]] || die "--env-file not found: $env_file"
    fi

    # --- Allocate host port ---
    local host_port
    host_port="$(app_port_alloc)"

    local data_dir container_name
    data_dir="$(app_data_dir "$name")"
    container_name="$(app_container_name "$name")"

    log_info "Creating app: $name"
    printf '  Domain:        %s\n' "$domain"
    printf '  Image:         %s\n' "$image"
    printf '  Internal port: %s\n' "$internal_port"
    printf '  Host port:     127.0.0.1:%s\n' "$host_port"
    printf '  Container:     %s\n' "$container_name"
    printf '  Data dir:      %s\n' "$data_dir"
    [[ -n "$memory_limit" ]] && printf '  Memory limit:  %s\n' "$memory_limit"
    printf '\n'

    local start_ts
    start_ts="$(date +%s)"
    local total=6

    # --- 1. Data directory ---
    log_step 1 $total "Setting up data directory"
    mkdir -p "$data_dir"
    chmod 750 "$data_dir"
    log_sub "Data dir ready: $data_dir"

    # --- 2. Pull image ---
    log_step 2 $total "Pulling Docker image"
    docker pull "$image" 2>&1 | tail -3 || die "Failed to pull image: $image"

    # --- 3. Run container ---
    log_step 3 $total "Starting container"
    # Remove any leftover container with the same name (idempotent re-create)
    docker rm -f "$container_name" >/dev/null 2>&1 || true

    local docker_run_args=(
        run -d
        --name "$container_name"
        --restart unless-stopped
        -p "127.0.0.1:${host_port}:${internal_port}"
        --label "mwp.app=${name}"
        --label "mwp.domain=${domain}"
    )
    [[ -n "$memory_limit" ]] && docker_run_args+=( --memory "$memory_limit" )
    [[ -n "$env_file"     ]] && docker_run_args+=( --env-file "$env_file" )
    [[ ${#env_args[@]}    -gt 0 ]] && docker_run_args+=( "${env_args[@]}" )
    [[ ${#volume_args[@]} -gt 0 ]] && docker_run_args+=( "${volume_args[@]}" )
    docker_run_args+=( "$image" )

    if ! docker "${docker_run_args[@]}" >/dev/null; then
        die "docker run failed. Check: docker logs ${container_name}"
    fi
    log_sub "Container started: $container_name"

    # Brief wait so the container has a moment to bind its listener before
    # nginx proxies the first request. 2s is enough for most apps; n8n / Next.js
    # cold start can take longer but proxy_pass will retry.
    sleep 2

    # --- 4. Nginx vhost ---
    log_step 4 $total "Creating Nginx reverse proxy"
    _app_create_nginx_vhost "$name" "$domain" "$host_port"

    # --- 5. Registry ---
    log_step 5 $total "Registering app"
    APP_DOMAIN="$domain" \
    APP_IMAGE="$image" \
    APP_INTERNAL_PORT="$internal_port" \
    APP_HOST_PORT="$host_port" \
    APP_MEMORY_LIMIT="$memory_limit" \
    APP_DATA_DIR="$data_dir" \
    APP_CONTAINER="$container_name" \
    app_registry_add "$name"

    # --- 6. SSL (best-effort) ---
    log_step 6 $total "Issuing SSL certificate"
    source "$MWP_DIR/lib/multi-ssl.sh"
    ssl_issue "$domain" || \
        log_warn "SSL setup failed — app is up on HTTP only. Retry: mwp ssl issue $domain"

    local elapsed=$(( $(date +%s) - start_ts ))
    printf '\n%b✔ App created in %ds%b\n' "$GREEN" "$elapsed" "$NC"

    printf '\n%b  ══════════════════════════════════════%b\n' "$GREEN" "$NC"
    printf '%b  App:        %b %s\n' "$BOLD" "$NC" "$name"
    printf '%b  URL:        %b http://%s\n' "$BOLD" "$NC" "$domain"
    printf '  Container:  %s\n' "$container_name"
    printf '  Port map:   127.0.0.1:%s → container:%s\n' "$host_port" "$internal_port"
    printf '  Data dir:   %s\n' "$data_dir"
    printf '%b  ══════════════════════════════════════%b\n\n' "$GREEN" "$NC"
    printf '  %bManage:%b mwp app info %s\n' "$BOLD" "$NC" "$name"
    printf '  %bLogs:  %b mwp app logs %s -f\n\n' "$BOLD" "$NC" "$name"
}

# ---------------------------------------------------------------------------
# Render the HTTP-only proxy vhost from template, enable, restart nginx.
# ---------------------------------------------------------------------------
_app_create_nginx_vhost() {
    local name="$1" domain="$2" host_port="$3"
    local conf_file="$NGINX_SITES_AVAILABLE/${domain}.conf"

    APP_NAME="$name" \
    DOMAIN="$domain" \
    HOST_PORT="$host_port" \
    GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S')" \
    render_template "$MWP_DIR/templates/nginx/proxy-app.conf.tpl" > "$conf_file"

    ln -sf "$conf_file" "$NGINX_SITES_ENABLED/${domain}.conf"
    nginx_test
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
    log_sub "Nginx vhost created: $conf_file"
}

# ---------------------------------------------------------------------------
# Append HTTPS server block to the proxy vhost. Called by ssl_issue dispatcher
# after the cert is in place. Mirrors nginx_enable_https() shape but emits a
# proxy block instead of an FPM block.
# ---------------------------------------------------------------------------
app_nginx_enable_https() {
    local name="$1" domain="$2"
    local cert_dir="${3:-/etc/letsencrypt/live/${domain}}"
    local conf="$NGINX_SITES_AVAILABLE/${domain}.conf"
    [[ -f "$conf" ]] || die "Nginx config not found for app: $conf"

    # Uncomment the redirect line in the HTTP block
    sed -i 's|# return 301 https://\$host\$request_uri;|return 301 https://$host$request_uri;|' "$conf"

    # If HTTPS block already exists, just refresh cert paths (LE → self-signed switch etc.)
    if grep -q "listen 443" "$conf"; then
        sed -i "s|ssl_certificate     .*/fullchain.pem;|ssl_certificate     ${cert_dir}/fullchain.pem;|" "$conf"
        sed -i "s|ssl_certificate_key .*/privkey.pem;|ssl_certificate_key ${cert_dir}/privkey.pem;|"     "$conf"
        log_sub "Updated cert paths in existing HTTPS block → ${cert_dir}/"
        nginx_reload
        return 0
    fi

    cat >> "$conf" <<HTTPS_BLOCK

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain};

    ssl_certificate     ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    add_header Strict-Transport-Security "max-age=63072000" always;

    access_log /var/log/nginx/mwp-app-${name}-access.log;
    error_log  /var/log/nginx/mwp-app-${name}-error.log warn;

    client_max_body_size 100M;

    location / {
        proxy_pass http://mwp_app_${name};
        proxy_http_version 1.1;

        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host  \$host;

        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_buffering off;
        proxy_cache off;

        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }
}
HTTPS_BLOCK

    nginx_reload
    log_sub "HTTPS enabled for $domain (cert: ${cert_dir})"
}

# ---------------------------------------------------------------------------
# Lifecycle: start / stop / restart
# ---------------------------------------------------------------------------
app_start() {
    require_root
    _load_app_deps
    docker_engine_check
    local name="${1:-}"
    [[ -z "$name" ]] && die "Usage: mwp app start <name>"
    app_exists "$name" || die "App '$name' not found."

    local container
    container="$(app_get "$name" CONTAINER)"
    docker start "$container" >/dev/null || die "Failed to start container: $container"
    app_set "$name" "STATUS" "running"
    log_success "App '$name' started."
}

app_stop() {
    require_root
    _load_app_deps
    docker_engine_check
    local name="${1:-}"
    [[ -z "$name" ]] && die "Usage: mwp app stop <name>"
    app_exists "$name" || die "App '$name' not found."

    local container
    container="$(app_get "$name" CONTAINER)"
    docker stop "$container" >/dev/null || die "Failed to stop container: $container"
    app_set "$name" "STATUS" "stopped"
    log_success "App '$name' stopped."
}

app_restart() {
    require_root
    _load_app_deps
    docker_engine_check
    local name="${1:-}"
    [[ -z "$name" ]] && die "Usage: mwp app restart <name>"
    app_exists "$name" || die "App '$name' not found."

    local container
    container="$(app_get "$name" CONTAINER)"
    docker restart "$container" >/dev/null || die "Failed to restart container: $container"
    app_set "$name" "STATUS" "running"
    log_success "App '$name' restarted."
}

# ---------------------------------------------------------------------------
# Logs / exec / shell — pass-through to docker
# ---------------------------------------------------------------------------
app_logs() {
    _load_app_deps
    docker_engine_check
    local name="${1:-}"; shift || true
    [[ -z "$name" ]] && die "Usage: mwp app logs <name> [-f] [-n N]"
    app_exists "$name" || die "App '$name' not found."

    local container
    container="$(app_get "$name" CONTAINER)"
    # Pass remaining args through (e.g. -f, -n 100, --since 1h)
    exec docker logs "$@" "$container"
}

app_exec() {
    require_root
    _load_app_deps
    docker_engine_check
    local name="${1:-}"; shift || true
    [[ -z "$name" ]] && die "Usage: mwp app exec <name> -- <cmd>"
    app_exists "$name" || die "App '$name' not found."

    # Drop a leading "--" if present (mwp app exec <name> -- ls /)
    [[ "${1:-}" == "--" ]] && shift
    [[ $# -gt 0 ]] || die "Usage: mwp app exec <name> -- <cmd> [args]"

    local container
    container="$(app_get "$name" CONTAINER)"
    # -t (allocate TTY) only when our own stdin IS a TTY. Without this guard,
    # `mwp app exec` over a non-interactive SSH / cron / CI pipe dies with:
    #   "cannot enable tty mode on non tty input"
    local docker_flags=( exec -i )
    [[ -t 0 ]] && docker_flags+=( -t )
    exec docker "${docker_flags[@]}" "$container" "$@"
}

app_shell() {
    require_root
    _load_app_deps
    docker_engine_check
    local name="${1:-}"
    [[ -z "$name" ]] && die "Usage: mwp app shell <name>"
    app_exists "$name" || die "App '$name' not found."

    local container
    container="$(app_get "$name" CONTAINER)"
    # A shell is useless without a TTY — refuse early with a clear hint
    # instead of letting docker emit its cryptic non-tty error.
    [[ -t 0 ]] || die "mwp app shell needs an interactive terminal. Use: mwp app exec $name -- <cmd>"
    # Try bash first, fall back to sh — alpine images don't ship bash.
    if docker exec -it "$container" sh -c 'command -v bash >/dev/null 2>&1'; then
        exec docker exec -it "$container" bash
    else
        exec docker exec -it "$container" sh
    fi
}

# ---------------------------------------------------------------------------
# app_delete — reverse of app_create
# ---------------------------------------------------------------------------
app_delete() {
    require_root
    _load_app_deps
    local name="${1:-}"
    [[ -z "$name" ]] && die "Usage: mwp app delete <name>"
    app_exists "$name" || die "App '$name' not found."

    local domain container data_dir
    domain="$(app_get "$name" DOMAIN)"
    container="$(app_get "$name" CONTAINER)"
    data_dir="$(app_get "$name" DATA_DIR)"

    printf '\n%bDelete app: %s%b\n' "$RED" "$name" "$NC"
    printf 'This will:\n'
    printf '  • Stop + remove container: %s\n' "$container"
    printf '  • Remove Nginx vhost for: %s\n' "$domain"
    printf '  • Remove SSL certificate (Let'"'"'s Encrypt or self-signed)\n'
    printf '  • Delete data directory: %s\n' "$data_dir"
    printf '  • Remove from registry\n\n'

    confirm "Type 'y' to confirm deletion of '$name'" || { log_info "Aborted."; return 0; }

    log_info "Deleting app: $name"

    # 1. Container
    if command -v docker >/dev/null 2>&1; then
        docker rm -f "$container" 2>/dev/null && log_sub "Container removed: $container" || true
    fi

    # 2. Nginx vhost
    nginx_delete_site "$domain" 2>/dev/null || true

    # 3. SSL cert
    certbot delete --cert-name "$domain" --non-interactive 2>/dev/null || true
    if [[ -d "/etc/mwp/ssl/${domain}" ]]; then
        rm -rf "/etc/mwp/ssl/${domain}"
        log_sub "Self-signed cert removed: /etc/mwp/ssl/${domain}"
    fi

    # 4. Data dir
    if [[ -d "$data_dir" ]]; then
        rm -rf "$data_dir"
        log_sub "Data dir removed: $data_dir"
    fi

    # 5. Registry
    app_registry_remove "$name"

    log_success "App '$name' deleted."
}
