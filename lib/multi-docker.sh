#!/usr/bin/env bash
# lib/multi-docker.sh — Docker engine setup + helpers for mwp apps
#
# docker_engine_install()  — install Docker CE from official repo, configure daemon.json,
#                            install nginx WS-upgrade map snippet
# docker_engine_check()    — die if docker not installed/running
# docker_engine_status()   — pretty-print engine status
# _docker_install_ws_map() — write /etc/nginx/conf.d/mwp-ws-upgrade.conf + ensure
#                            nginx.conf includes conf.d/*.conf

[[ -n "${_MWP_DOCKER_LOADED:-}" ]] && return 0
_MWP_DOCKER_LOADED=1

# ---------------------------------------------------------------------------
# Check Docker is installed & running. Use as guard before container ops.
# ---------------------------------------------------------------------------
docker_engine_check() {
    command -v docker >/dev/null 2>&1 || \
        die "Docker is not installed. Run: mwp docker install"
    systemctl is-active --quiet docker 2>/dev/null || \
        die "Docker engine is installed but not running. Run: systemctl start docker"
}

docker_engine_is_installed() {
    command -v docker >/dev/null 2>&1 && \
        systemctl is-active --quiet docker 2>/dev/null
}

# ---------------------------------------------------------------------------
# Pretty-print engine status — used by `mwp docker status`
# ---------------------------------------------------------------------------
docker_engine_status() {
    printf '\n%b  Docker engine%b\n' "$BOLD" "$NC"
    printf '  %s\n' "──────────────────────────────────────"

    if ! command -v docker >/dev/null 2>&1; then
        printf '  Status:  %bnot installed%b\n' "$RED" "$NC"
        printf '  Install: mwp docker install\n\n'
        return 0
    fi

    local ver
    ver="$(docker --version 2>/dev/null | head -1)"
    printf '  Version: %s\n' "${ver:-unknown}"

    if systemctl is-active --quiet docker 2>/dev/null; then
        printf '  Service: %bactive%b\n' "$GREEN" "$NC"
    else
        printf '  Service: %binactive%b\n' "$RED" "$NC"
    fi

    local container_count image_count
    container_count="$(docker ps -q 2>/dev/null | wc -l)"
    image_count="$(docker images -q 2>/dev/null | wc -l)"
    printf '  Running: %s container(s)\n' "$container_count"
    printf '  Images:  %s\n' "$image_count"

    local installed_at
    installed_at="$(server_get "DOCKER_INSTALLED_AT")"
    [[ -n "$installed_at" ]] && printf '  Since:   %s\n' "$installed_at"
    printf '\n'
}

# ---------------------------------------------------------------------------
# Install Docker CE from Docker's official repo. Idempotent.
# ---------------------------------------------------------------------------
docker_engine_install() {
    require_root

    if docker_engine_is_installed; then
        log_info "Docker is already installed and running."
        log_sub "$(docker --version 2>/dev/null | head -1)"
        # Still ensure WS map snippet is present (cheap, idempotent)
        _docker_install_ws_map
        return 0
    fi

    log_info "Installing Docker CE from docker.com official repo..."

    # --- Repo + key ---
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        log_sub "Adding Docker GPG key..."
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
            gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    local codename arch
    codename="$( . /etc/os-release && echo "$VERSION_CODENAME" )"
    arch="$(dpkg --print-architecture)"
    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable
EOF

    apt_wait
    apt-get update -qq 2>&1 | tail -1 || true

    log_sub "Installing docker-ce, docker-cli, containerd, buildx, compose..."
    apt_install docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin

    # --- daemon.json: log rotation (containers can spam multi-GB logs) ---
    mkdir -p /etc/docker
    if [[ ! -f /etc/docker/daemon.json ]]; then
        cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
JSON
        log_sub "daemon.json: log rotation 10m × 3 + live-restore enabled"
    else
        log_sub "daemon.json already exists — leaving as-is"
    fi

    systemctl enable docker 2>/dev/null || true
    systemctl restart docker

    # --- Nginx: WebSocket upgrade map ---
    _docker_install_ws_map

    server_set "DOCKER_INSTALLED_AT" "$(date '+%Y-%m-%d %H:%M:%S')"
    log_success "Docker engine ready: $(docker --version 2>/dev/null)"
    log_sub "Next: mwp app create <name> --domain <d> --image <img> --port <p>"
}

# ---------------------------------------------------------------------------
# Install Nginx WebSocket-upgrade map snippet.
#
# Apps proxied through nginx (n8n, Next.js HMR, etc.) need:
#     map $http_upgrade $connection_upgrade {
#         default upgrade;
#         ''      close;
#     }
# in the http{} context. install.sh's nginx.conf doesn't include /etc/nginx/conf.d
# by default, so we patch it to include conf.d AND drop the map snippet there.
#
# Idempotent: safe to call repeatedly.
# ---------------------------------------------------------------------------
_docker_install_ws_map() {
    local map_file="/etc/nginx/conf.d/mwp-ws-upgrade.conf"
    local nginx_conf="/etc/nginx/nginx.conf"

    [[ -d /etc/nginx/conf.d ]] || mkdir -p /etc/nginx/conf.d

    if [[ ! -f "$map_file" ]]; then
        cat > "$map_file" <<'NGINXMAP'
# mwp — WebSocket upgrade map for proxied apps
# Required by templates/nginx/proxy-app.conf.tpl
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
NGINXMAP
        log_sub "WebSocket upgrade map installed: $map_file"
    fi

    # Ensure nginx.conf includes /etc/nginx/conf.d/*.conf in http {}.
    # install.sh writes nginx.conf with only sites-enabled include — patch in conf.d.
    if [[ -f "$nginx_conf" ]] && ! grep -q "include /etc/nginx/conf.d" "$nginx_conf"; then
        # Insert right before the sites-enabled include
        sed -i 's|^\(\s*\)include /etc/nginx/sites-enabled/\*\.conf;|\1include /etc/nginx/conf.d/*.conf;\n\1include /etc/nginx/sites-enabled/*.conf;|' \
            "$nginx_conf"
        log_sub "Patched nginx.conf to include /etc/nginx/conf.d/*.conf"
    fi

    # Validate + reload (skip silently if nginx not yet installed)
    if command -v nginx >/dev/null 2>&1; then
        if nginx -t 2>/dev/null; then
            systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
        else
            log_warn "nginx -t failed after WS-map install. Run: nginx -t"
        fi
    fi
}
