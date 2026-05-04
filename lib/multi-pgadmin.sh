#!/usr/bin/env bash
# lib/multi-pgadmin.sh — pgAdmin 4 deployed as a Docker app, mounted at
# pgadmin.<panel-apex> with auto SSL.
#
# Architecture: thin wrapper around `mwp app create` using the official
# dpage/pgadmin4 image. Container reaches host postgres via the docker0
# bridge IP (172.17.0.1) — UFW already allows that path (mwp pg install).
#
# Auth: pgAdmin's built-in (server mode), single admin user seeded from
# email + password env vars during first start. Both saved to
# /etc/mwp/pgadmin.conf (mode 600) so admins can recover later.

[[ -n "${_MWP_PGADMIN_LOADED:-}" ]] && return 0
_MWP_PGADMIN_LOADED=1

PGADMIN_CONF="/etc/mwp/pgadmin.conf"
PGADMIN_APP_NAME="pgadmin"
PGADMIN_IMAGE="dpage/pgadmin4:latest"
PGADMIN_DATA_DIR="/var/lib/mwp/apps/pgadmin/data"
PGADMIN_SERVERS_JSON="${PGADMIN_DATA_DIR}/servers.json"
PG_DBS_DIR="/etc/mwp/pg-dbs"

_pgadmin_resolve_domain() {
    # Default: pgadmin.<panel-apex>. Caller can override.
    local panel_domain
    panel_domain="$(server_get PANEL_DOMAIN)"
    [[ -z "$panel_domain" ]] && return 1
    # Strip first label: sv1.azsmarthub.com → azsmarthub.com
    printf 'pgadmin.%s' "${panel_domain#*.}"
}

_pgadmin_is_installed() {
    [[ -f "$PGADMIN_CONF" ]]
}

# ---------------------------------------------------------------------------
# pgadmin_render_servers_json
# Generate /var/lib/mwp/apps/pgadmin/data/servers.json from
# /etc/mwp/pg-dbs/*.conf so pgAdmin can pre-register all mwp-managed DBs.
# Imported automatically on first container start (PGADMIN_SERVER_JSON_FILE).
# To re-import after install: pgadmin_reload_servers.
# ---------------------------------------------------------------------------
pgadmin_render_servers_json() {
    require_root
    mkdir -p "$PGADMIN_DATA_DIR"

    local entries="" n=0 conf
    for conf in "$PG_DBS_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        # Use a subshell so env vars from each conf don't leak between iterations
        local entry
        entry="$(
            # shellcheck source=/dev/null
            source "$conf"
            cat <<EOF
    "$((n + 1))": {
      "Name": "${DB_NAME}",
      "Group": "mwp",
      "Host": "172.17.0.1",
      "Port": 5432,
      "MaintenanceDB": "${DB_NAME}",
      "Username": "${DB_USER}",
      "SSLMode": "prefer",
      "Comment": "mwp-managed (created ${CREATED_AT})"
    }
EOF
        )"
        n=$((n + 1))
        if [[ -z "$entries" ]]; then
            entries="$entry"
        else
            entries="${entries},
${entry}"
        fi
    done

    if [[ $n -eq 0 ]]; then
        cat > "$PGADMIN_SERVERS_JSON" <<JSON
{
  "Servers": {}
}
JSON
    else
        cat > "$PGADMIN_SERVERS_JSON" <<JSON
{
  "Servers": {
${entries}
  }
}
JSON
    fi
    chown 5050:5050 "$PGADMIN_SERVERS_JSON" 2>/dev/null || true
    chmod 644 "$PGADMIN_SERVERS_JSON"
}

# ---------------------------------------------------------------------------
# pgadmin_reload_servers — re-import servers.json into pgAdmin's user DB.
# Called automatically after `mwp pg db create / drop` (silent).
# pgAdmin only auto-imports on first run, so for incremental updates we run
# setup.py inside the container with --replace.
# ---------------------------------------------------------------------------
pgadmin_reload_servers() {
    require_root
    _pgadmin_is_installed || return 0
    # shellcheck source=/dev/null
    source "$PGADMIN_CONF"

    pgadmin_render_servers_json

    if ! docker ps --format '{{.Names}}' | grep -q "^mwp-${PGADMIN_APP_NAME}\$"; then
        log_sub "pgAdmin container not running — JSON regenerated, skipping import."
        return 0
    fi

    # IMPORTANT: must use /venv/bin/python3 — the official image's setup.py
    # imports `typer` which is only in the venv, not in the system python.
    # Argument order matches dpage/pgadmin4's own entrypoint.sh:
    #   setup.py load-servers <json_path> --user <email> [--replace]
    if docker exec "mwp-${PGADMIN_APP_NAME}" \
        /venv/bin/python3 /pgadmin4/setup.py load-servers \
        /var/lib/pgadmin/servers.json \
        --user "$EMAIL" \
        --replace >/dev/null 2>&1; then
        log_sub "pgAdmin server list refreshed."
    else
        log_warn "pgAdmin server import failed — re-run: mwp pgadmin reload-servers"
    fi
}

# ---------------------------------------------------------------------------
# pgadmin_install [domain]
# Default domain: pgadmin.<panel-apex>
# ---------------------------------------------------------------------------
pgadmin_install() {
    require_root

    if _pgadmin_is_installed; then
        local existing_domain
        existing_domain="$(grep '^DOMAIN=' "$PGADMIN_CONF" | cut -d= -f2-)"
        log_info "pgAdmin already installed at https://${existing_domain}"
        printf '  Credentials: cat %s\n' "$PGADMIN_CONF"
        printf '  Reinstall:   mwp pgadmin uninstall && mwp pgadmin install\n\n'
        return 0
    fi

    local panel_domain
    panel_domain="$(server_get PANEL_DOMAIN)"
    [[ -z "$panel_domain" ]] && die "Panel hostname not configured. Run: mwp panel setup"

    local pgadmin_domain
    pgadmin_domain="${1:-$(_pgadmin_resolve_domain)}"
    validate_domain "$pgadmin_domain" || die "Invalid pgAdmin domain: $pgadmin_domain"

    # Load app deps so app_create + app_exists are available
    source "$MWP_DIR/lib/multi-docker.sh"
    source "$MWP_DIR/lib/app-registry.sh"
    source "$MWP_DIR/lib/multi-nginx.sh"
    source "$MWP_DIR/lib/multi-app.sh"

    # Don't clobber an existing app with the reserved name
    if app_exists "$PGADMIN_APP_NAME"; then
        die "Docker app '$PGADMIN_APP_NAME' already exists outside mwp pgadmin tracking. Inspect: mwp app info $PGADMIN_APP_NAME"
    fi

    # Generate creds — email format must be valid (pgAdmin rejects garbage)
    local apex email password
    apex="${panel_domain#*.}"
    email="admin@${apex}"
    password="$(generate_password 20)"

    log_info "Installing pgAdmin..."
    log_sub "Domain:    $pgadmin_domain"
    log_sub "Admin:     $email"

    # Save credentials BEFORE app_create so we have a record even if create fails
    mkdir -p "$(dirname "$PGADMIN_CONF")"
    cat > "$PGADMIN_CONF" <<EOF
DOMAIN=${pgadmin_domain}
EMAIL=${email}
PASSWORD=${password}
APP_NAME=${PGADMIN_APP_NAME}
INSTALLED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    chmod 600 "$PGADMIN_CONF"

    # Container env. PGADMIN_CONFIG_SERVER_MODE=True → multi-user mode with
    # email/password login (matches user choice — built-in auth, not magic-link).
    # PGADMIN_DISABLE_POSTFIX=True so the image doesn't try to start a
    # mailer it doesn't need (saves ~30s startup).
    # PGADMIN_SERVER_JSON_FILE → pre-register all mwp-managed postgres DBs.
    mkdir -p "$PGADMIN_DATA_DIR"
    chown 5050:5050 "$PGADMIN_DATA_DIR" 2>/dev/null || true

    # Generate servers.json BEFORE first container start so pgAdmin auto-imports
    pgadmin_render_servers_json

    if ! app_create "$PGADMIN_APP_NAME" \
        --domain "$pgadmin_domain" \
        --image "$PGADMIN_IMAGE" \
        --port 80 \
        --memory 512m \
        --env "PGADMIN_DEFAULT_EMAIL=$email" \
        --env "PGADMIN_DEFAULT_PASSWORD=$password" \
        --env "PGADMIN_LISTEN_PORT=80" \
        --env "PGADMIN_CONFIG_SERVER_MODE=True" \
        --env "PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED=False" \
        --env "PGADMIN_DISABLE_POSTFIX=True" \
        --env "PGADMIN_SERVER_JSON_FILE=/var/lib/pgadmin/servers.json" \
        --volume "${PGADMIN_DATA_DIR}:/var/lib/pgadmin"; then
        rm -f "$PGADMIN_CONF"
        die "app_create failed for pgAdmin — see output above"
    fi

    # Resolve final URL — app_create issues SSL best-effort
    local scheme="http"
    [[ -f "/etc/letsencrypt/live/${pgadmin_domain}/fullchain.pem" ]] && scheme="https"

    printf '\n%b  pgAdmin ready%b\n' "$GREEN" "$NC"
    printf '  %s\n' "──────────────────────────────────────────────"
    printf '  URL:       %s://%s\n' "$scheme" "$pgadmin_domain"
    printf '  Email:     %s\n' "$email"
    printf '  Password:  %b%s%b\n' "$BOLD" "$password" "$NC"
    printf '  Creds:     %s\n\n' "$PGADMIN_CONF"
    printf '  %bConnect to local postgres:%b host=172.17.0.1, port=5432\n' "$DIM" "$NC"
    printf '  %b                          %b user/db: from `mwp pg db info <name>`\n\n' "$DIM" "$NC"
}

# ---------------------------------------------------------------------------
# pgadmin_uninstall — remove container + nginx + creds + data
# ---------------------------------------------------------------------------
pgadmin_uninstall() {
    require_root
    if ! _pgadmin_is_installed; then
        log_info "pgAdmin is not installed (no $PGADMIN_CONF)."
        # Still try to clean up an orphan app entry just in case
        if [[ -f "$MWP_APPS_DIR/${PGADMIN_APP_NAME}.conf" ]]; then
            log_warn "Found orphan app entry — cleaning up."
        else
            return 0
        fi
    fi

    confirm "Uninstall pgAdmin — removes container + nginx vhost + DATA. Continue?" \
        || { log_info "Aborted."; return 0; }

    source "$MWP_DIR/lib/multi-docker.sh"
    source "$MWP_DIR/lib/app-registry.sh"
    source "$MWP_DIR/lib/multi-nginx.sh"
    source "$MWP_DIR/lib/multi-app.sh"

    if app_exists "$PGADMIN_APP_NAME"; then
        # app_delete handles container + nginx + registry. Pipe a 'y' so its
        # confirm() doesn't block — we already confirmed at our level.
        yes y | app_delete "$PGADMIN_APP_NAME" >/dev/null 2>&1 || true
    fi

    rm -rf "$PGADMIN_DATA_DIR"
    rm -f "$PGADMIN_CONF"

    log_success "pgAdmin removed."
}

# ---------------------------------------------------------------------------
# pgadmin_status — install state + container health
# ---------------------------------------------------------------------------
pgadmin_status() {
    printf '\n%b  pgAdmin status%b\n' "$BOLD" "$NC"
    printf '  %s\n' "──────────────────────────────────"

    if ! _pgadmin_is_installed; then
        printf '  Installed:  %bno%b\n' "$YELLOW" "$NC"
        printf '  Install:    mwp pgadmin install\n\n'
        return 0
    fi

    # shellcheck source=/dev/null
    source "$PGADMIN_CONF"

    local container_state="unknown"
    if command -v docker >/dev/null 2>&1; then
        # Container naming follows app_container_name() in lib/multi-app.sh:
        # "mwp-<name>" — NOT "mwp-app-<name>".
        container_state="$(docker inspect -f '{{.State.Status}}' "mwp-${PGADMIN_APP_NAME}" 2>/dev/null || echo missing)"
    fi

    local scheme="http"
    [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] && scheme="https"

    printf '  Installed:    %byes%b  (%s)\n' "$GREEN" "$NC" "$INSTALLED_AT"
    printf '  Domain:       %s\n' "$DOMAIN"
    printf '  URL:          %s://%s\n' "$scheme" "$DOMAIN"
    printf '  Admin email:  %s\n' "$EMAIL"
    printf '  Container:    %s\n' "$container_state"
    printf '  Data:         %s\n' "$PGADMIN_DATA_DIR"
    printf '  Creds file:   %s\n\n' "$PGADMIN_CONF"
}

# ---------------------------------------------------------------------------
# pgadmin_url — quick print of URL + login email (no password)
# ---------------------------------------------------------------------------
pgadmin_url() {
    _pgadmin_is_installed || die "pgAdmin not installed."
    # shellcheck source=/dev/null
    source "$PGADMIN_CONF"
    local scheme="http"
    [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] && scheme="https"
    printf '%s://%s\n' "$scheme" "$DOMAIN"
    printf 'Login: %s  (password in %s)\n' "$EMAIL" "$PGADMIN_CONF"
}
