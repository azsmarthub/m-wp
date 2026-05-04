#!/usr/bin/env bash
# lib/multi-pma.sh — phpMyAdmin via panel hostname (single-use magic links)
#
# Pattern: each `mwp db pma <domain>` generates a random URL like
#   https://sv1.<panel>/db-<24chars>/
# that auto-logs into ONLY that site's DB. The link binds to the first
# browser that hits it (cookie-locked) and auto-expires after 24h.
#
# Architecture:
#   - One shared phpMyAdmin install at /usr/share/phpmyadmin (apt)
#   - Dedicated PHP-FPM pool `mwp-pma` (user mwp-pma, isolated open_basedir)
#   - Router config at /etc/phpmyadmin/conf.d/mwp-router.php — dispatches
#     by URL prefix and applies per-link autologin credentials
#   - Link files at /etc/mwp/pma-links/<slug>-<rand>.php — readable+writable
#     by the mwp-pma pool (router persists `claimed_token` on first hit)
#   - Nginx snippet at /etc/nginx/snippets/mwp-pma.conf — regenerated on
#     every link create/revoke/sweep, included into the panel vhost
#   - Sweeper cron every 5 minutes deletes expired link files

[[ -n "${_MWP_PMA_LOADED:-}" ]] && return 0
_MWP_PMA_LOADED=1

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
PMA_LINKS_DIR="/etc/mwp/pma-links"
PMA_NGINX_SNIPPET="/etc/nginx/snippets/mwp-pma.conf"
PMA_PANEL_VHOST="/etc/nginx/sites-available/mwp-panel.conf"
PMA_ROUTER_CONF="/etc/phpmyadmin/conf.d/mwp-router.php"
PMA_SWEEP_CRON="/etc/cron.d/mwp-pma-sweep"
PMA_DEFAULT_TTL_HOURS=24
PMA_USER="mwp-pma"
PMA_INCLUDE_LINE='    include /etc/nginx/snippets/mwp-pma.conf;'

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
_pma_default_php() {
    local v
    v="$(server_get "DEFAULT_PHP")"
    printf '%s' "${v:-8.3}"
}

_pma_pool_conf() {
    printf '/etc/php/%s/fpm/pool.d/mwp-pma.conf' "$(_pma_default_php)"
}

_pma_fpm_service() {
    printf 'php%s-fpm' "$(_pma_default_php)"
}

_pma_is_installed() {
    [[ "$(server_get "PMA_INSTALLED")" == "yes" ]]
}

_pma_require_installed() {
    _pma_is_installed || die "phpMyAdmin not installed. Run: mwp db pma install"
}

_pma_require_panel() {
    local pd
    pd="$(server_get "PANEL_DOMAIN")"
    [[ -z "$pd" ]] && die "Panel hostname not configured. Run: mwp panel setup"
    [[ -f "$PMA_PANEL_VHOST" ]] || die "Panel vhost not found at $PMA_PANEL_VHOST. Run: mwp panel setup"
    printf '%s' "$pd"
}

# Generate URL-safe random 24-char path component (~144 bits entropy)
_pma_rand_path() {
    # Subshell + pipefail off — head closing the pipe SIGPIPEs tr otherwise
    (
        set +o pipefail
        openssl rand -base64 48 2>/dev/null \
          | tr -d '/+=\n' \
          | head -c 24
    )
}

# Inject `include /etc/nginx/snippets/mwp-pma.conf;` into the panel vhost.
# Targets every server block's closing `}` (column-0 only) so HTTP + HTTPS
# variants both pick up the include after `mwp panel ssl` adds a second
# server { ... }. Inner `}` lines (locations, etc.) are indented and skipped.
# Idempotent — removes any prior copy first.
_pma_inject_panel_include() {
    [[ -f "$PMA_PANEL_VHOST" ]] || return 0
    sed -i '/snippets\/mwp-pma\.conf/d' "$PMA_PANEL_VHOST"
    sed -i "s|^}$|${PMA_INCLUDE_LINE}\n}|" "$PMA_PANEL_VHOST"
}

_pma_remove_panel_include() {
    [[ -f "$PMA_PANEL_VHOST" ]] || return 0
    sed -i '/snippets\/mwp-pma\.conf/d' "$PMA_PANEL_VHOST"
}

# Reload nginx after validating config — refuse to break a working server
_pma_nginx_reload() {
    if nginx -t >/dev/null 2>&1; then
        service_reload nginx
        return 0
    fi
    log_error "nginx -t failed after pma changes:"
    nginx -t 2>&1 | tail -5 >&2 || true
    return 1
}

# Print all active link files (optionally filtered by domain slug prefix)
_pma_link_files() {
    local domain="${1:-}"
    local pattern="$PMA_LINKS_DIR"
    if [[ -n "$domain" ]]; then
        local slug
        slug="$(domain_to_slug "$domain")"
        pattern="$PMA_LINKS_DIR/${slug}-*.php"
    else
        pattern="$PMA_LINKS_DIR/*.php"
    fi
    # Use compgen so unmatched globs return nothing instead of a literal pattern
    compgen -G "$pattern" 2>/dev/null || true
}

# Extract a single field from a link file (PHP returns an array literal)
# Field syntax: simple grep — works because we control the writer format.
_pma_link_field() {
    local file="$1" field="$2"
    grep -oP "'${field}'\s*=>\s*'[^']*'" "$file" 2>/dev/null \
      | head -1 \
      | sed -E "s|^'${field}'\s*=>\s*'(.*)'$|\1|"
}

_pma_link_int_field() {
    local file="$1" field="$2"
    grep -oP "'${field}'\s*=>\s*[0-9]+" "$file" 2>/dev/null \
      | head -1 \
      | grep -oE '[0-9]+$'
}

# ---------------------------------------------------------------------------
# pma_install — one-time setup
# ---------------------------------------------------------------------------
pma_install() {
    require_root
    _pma_require_panel >/dev/null

    if _pma_is_installed; then
        log_info "phpMyAdmin already installed. Run 'mwp db pma status' for details."
        return 0
    fi

    local php_ver pool_conf fpm_svc
    php_ver="$(_pma_default_php)"
    pool_conf="$(_pma_pool_conf)"
    fpm_svc="$(_pma_fpm_service)"

    log_info "Installing phpMyAdmin (PHP ${php_ver})..."

    # 1. apt — phpmyadmin pulls php-mbstring + php-zip if missing
    if [[ ! -d /usr/share/phpmyadmin ]]; then
        log_sub "Installing phpmyadmin package..."
        # Pre-seed debconf so apt doesn't prompt for webserver/dbconfig choices
        echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
        echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect" | debconf-set-selections
        apt_install phpmyadmin
    else
        log_sub "phpmyadmin package already present"
    fi

    # 2. Dedicated user (no shell, no home worth keeping)
    if ! id "$PMA_USER" &>/dev/null; then
        useradd --system --shell /usr/sbin/nologin --no-create-home --user-group "$PMA_USER"
        log_sub "User created: $PMA_USER"
    fi

    # 3. PHP-FPM pool
    GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S')" \
        render_template "$MWP_DIR/templates/php/multi-pma-pool.conf.tpl" > "$pool_conf"
    chmod 644 "$pool_conf"
    # Ensure session save dir exists + writable
    mkdir -p /var/lib/phpmyadmin/tmp
    chown -R "$PMA_USER:$PMA_USER" /var/lib/phpmyadmin/tmp
    chmod 700 /var/lib/phpmyadmin/tmp
    log_sub "FPM pool installed: $pool_conf"

    # 4. Link files dir — readable+writable by pma pool only.
    # Also +x on /etc/mwp so the pma pool user (which is "other" relative to
    # /etc/mwp's root:root ownership) can traverse INTO pma-links. Subdirs
    # like /etc/mwp/sites stay 700 root, so server.conf + site creds remain
    # unreadable to mwp-pma. 711 only exposes that /etc/mwp exists, not its
    # contents. Without this, the router gets is_dir() = false and bails
    # silently — single-use binding never fires.
    chmod o+x "$MWP_STATE_DIR" 2>/dev/null || true
    mkdir -p "$PMA_LINKS_DIR"
    chown "$PMA_USER:$PMA_USER" "$PMA_LINKS_DIR"
    chmod 700 "$PMA_LINKS_DIR"

    # 5. Router config (dispatches autologin per URL prefix)
    mkdir -p /etc/phpmyadmin/conf.d
    cp "$MWP_DIR/templates/pma/router.php.tpl" "$PMA_ROUTER_CONF"
    chmod 644 "$PMA_ROUTER_CONF"
    log_sub "Router config installed: $PMA_ROUTER_CONF"

    # 6. Empty nginx snippet (panel vhost includes it; must exist for nginx -t).
    # Ensure /etc/nginx/snippets/ exists — Ubuntu's nginx package doesn't create
    # it by default; only Debian's does.
    mkdir -p "$(dirname "$PMA_NGINX_SNIPPET")"
    : > "$PMA_NGINX_SNIPPET"
    chmod 644 "$PMA_NGINX_SNIPPET"

    # 7. Inject include into panel vhost
    _pma_inject_panel_include
    log_sub "Panel vhost patched: include $PMA_NGINX_SNIPPET"

    # 8. Sweep cron — every 5 minutes
    cat > "$PMA_SWEEP_CRON" <<CRON
# mwp: expire phpMyAdmin magic links after their TTL
*/5 * * * * root /usr/local/bin/mwp db pma sweep > /dev/null 2>&1
CRON
    chmod 644 "$PMA_SWEEP_CRON"

    # 9. Restart FPM (pool is new) + reload nginx
    service_restart "$fpm_svc"
    if ! _pma_nginx_reload; then
        log_warn "nginx reload failed — rolling back panel vhost change"
        _pma_remove_panel_include
        _pma_nginx_reload || true
        die "phpMyAdmin install aborted (nginx config invalid)"
    fi

    server_set "PMA_INSTALLED" "yes"
    server_set "PMA_INSTALLED_AT" "$(date '+%Y-%m-%d %H:%M:%S')"
    server_set "PMA_PHP_VERSION" "$php_ver"

    log_success "phpMyAdmin installed."
    printf '\n  %bGenerate a login link:%b\n' "$BOLD" "$NC"
    printf '    mwp db pma <domain>\n\n'
}

# ---------------------------------------------------------------------------
# pma_uninstall — full removal
# ---------------------------------------------------------------------------
pma_uninstall() {
    require_root

    if ! _pma_is_installed && [[ ! -f "$PMA_NGINX_SNIPPET" ]]; then
        log_info "phpMyAdmin is not installed."
        return 0
    fi

    confirm "Remove phpMyAdmin + all magic links + uninstall package?" \
        || { log_info "Aborted."; return 0; }

    # Revoke first so nothing gets dispatched while we tear down
    pma_revoke_all_silent

    rm -f "$PMA_SWEEP_CRON"
    rm -f "$PMA_ROUTER_CONF"
    rm -f "$PMA_NGINX_SNIPPET"
    _pma_remove_panel_include

    local pool_conf fpm_svc
    pool_conf="$(_pma_pool_conf)"
    fpm_svc="$(_pma_fpm_service)"
    rm -f "$pool_conf"

    # Drop pma package + autoremove orphaned deps. Keep the user (cheap to leave,
    # avoids issues if files we missed still own anything).
    apt_wait
    DEBIAN_FRONTEND=noninteractive apt-get remove -y -q phpmyadmin >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -q >/dev/null 2>&1 || true

    rm -rf "$PMA_LINKS_DIR"

    systemctl restart "$fpm_svc" 2>/dev/null || true
    _pma_nginx_reload || true

    # Clear server.conf flags
    sed -i '/^PMA_INSTALLED=/d;/^PMA_INSTALLED_AT=/d;/^PMA_PHP_VERSION=/d' \
        "$MWP_SERVER_CONF" 2>/dev/null || true

    log_success "phpMyAdmin removed."
}

# ---------------------------------------------------------------------------
# pma_create_link <domain> [ttl_hours]
# Generates a single-use magic link. Default TTL: 24h.
# ---------------------------------------------------------------------------
pma_create_link() {
    require_root
    local domain="${1:-}"
    local ttl_hours="${2:-$PMA_DEFAULT_TTL_HOURS}"

    [[ -z "$domain" ]] && die "Usage: mwp db pma <domain> [ttl_hours]"
    site_exists "$domain" || die "Site '$domain' not found in registry."
    [[ "$ttl_hours" =~ ^[0-9]+$ ]] || die "TTL must be a positive integer (got: $ttl_hours)"
    (( ttl_hours > 0 && ttl_hours <= 168 )) || die "TTL must be 1..168 hours (got: $ttl_hours)"

    _pma_require_installed
    local panel_domain
    panel_domain="$(_pma_require_panel)"

    local slug db_name db_user db_pass
    slug="$(domain_to_slug "$domain")"
    db_name="$(site_get "$domain" DB_NAME)"
    db_user="$(site_get "$domain" DB_USER)"
    db_pass="$(site_get "$domain" DB_PASS)"
    [[ -z "$db_user" || -z "$db_pass" ]] && die "Site '$domain' has no DB credentials in registry."

    local rand pma_path expires_ts created_ts created_ip
    rand="$(_pma_rand_path)"
    pma_path="/db-${rand}/"
    created_ts="$(date +%s)"
    expires_ts=$(( created_ts + ttl_hours * 3600 ))
    created_ip="${SUDO_USER_IP:-${SSH_CLIENT%% *}}"
    [[ -z "$created_ip" ]] && created_ip="local"

    local link_file="$PMA_LINKS_DIR/${slug}-${rand}.php"

    # Write link file via heredoc — escape single quotes in db_pass with var_export-style literal.
    # We use printf with %q-safe quoting via an inline PHP-friendly format.
    local esc_db_pass esc_db_user esc_db_name esc_domain
    esc_db_pass="$(printf '%s' "$db_pass" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g")"
    esc_db_user="$(printf '%s' "$db_user" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g")"
    esc_db_name="$(printf '%s' "$db_name" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g")"
    esc_domain="$(printf '%s' "$domain" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g")"

    cat > "$link_file" <<PHP
<?php return array (
  'path' => '${pma_path}',
  'slug' => '${slug}',
  'domain' => '${esc_domain}',
  'db_name' => '${esc_db_name}',
  'user' => '${esc_db_user}',
  'pass' => '${esc_db_pass}',
  'created' => ${created_ts},
  'expires' => ${expires_ts},
  'created_ip' => '${created_ip}',
  'claimed_token' => '',
  'claimed_at' => 0,
  'claimed_ip' => '',
);
PHP
    chown "$PMA_USER:$PMA_USER" "$link_file"
    chmod 600 "$link_file"

    pma_render_nginx_snippet
    _pma_nginx_reload || {
        rm -f "$link_file"
        pma_render_nginx_snippet
        _pma_nginx_reload || true
        die "nginx reload failed — link rolled back"
    }

    # Determine scheme — prefer https if panel SSL active
    local scheme="http"
    local ssl_active
    ssl_active="$(site_get "mwp-panel" SSL_ENABLED 2>/dev/null || true)"
    if [[ "$ssl_active" == "yes" ]] \
       || [[ -f "/etc/letsencrypt/live/${panel_domain}/fullchain.pem" ]]; then
        scheme="https"
    fi
    if [[ "$scheme" == "http" ]]; then
        log_warn "Panel has no SSL — link will travel in plaintext. Run: mwp panel ssl"
    fi

    local url="${scheme}://${panel_domain}${pma_path}"
    local human_expiry
    human_expiry="$(date -d "@$expires_ts" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || printf '%s' "$expires_ts")"

    printf '\n%b  phpMyAdmin magic-link for %s%b\n' "$BOLD" "$domain" "$NC"
    printf '  %s\n' "──────────────────────────────────────────────────────────"
    printf '  %s\n\n' "$url"
    printf '  DB:         %s (user: %s)\n' "$db_name" "$db_user"
    printf '  Expires:    %s  (%sh)\n' "$human_expiry" "$ttl_hours"
    printf '  %bSingle-use.%b First browser to open it locks the link;\n' "$DIM" "$NC"
    printf '  %b           %b further browsers get HTTP 403.\n\n' "$DIM" "$NC"
}

# ---------------------------------------------------------------------------
# pma_create_admin_link [ttl_hours]
# Generates a magic link that auto-logs in as MariaDB root — phpMyAdmin
# sees ALL databases on the server. Default TTL 6h (shorter than per-site
# 24h since the blast radius is bigger).
#
# Same single-use cookie binding as per-site links. Marker `is_admin=true`
# in the link file lets `pma list` render it red + labeled "ALL DBs".
# ---------------------------------------------------------------------------
PMA_ADMIN_DEFAULT_TTL_HOURS=6

pma_create_admin_link() {
    require_root
    local ttl_hours="${1:-$PMA_ADMIN_DEFAULT_TTL_HOURS}"
    [[ "$ttl_hours" =~ ^[0-9]+$ ]] || die "TTL must be a positive integer (got: $ttl_hours)"
    (( ttl_hours > 0 && ttl_hours <= 168 )) || die "TTL must be 1..168 hours (got: $ttl_hours)"

    _pma_require_installed
    local panel_domain
    panel_domain="$(_pma_require_panel)"

    local root_pass
    root_pass="$(server_get "DB_ROOT_PASS")"
    [[ -z "$root_pass" ]] && die "DB_ROOT_PASS not set in $MWP_SERVER_CONF — cannot create admin link."

    local rand pma_path expires_ts created_ts created_ip
    rand="$(_pma_rand_path)"
    pma_path="/db-${rand}/"
    created_ts="$(date +%s)"
    expires_ts=$(( created_ts + ttl_hours * 3600 ))
    created_ip="${SSH_CLIENT%% *}"
    [[ -z "$created_ip" ]] && created_ip="local"

    # Slug "_admin" — file naming convention so list/revoke can spot it
    local link_file="$PMA_LINKS_DIR/_admin-${rand}.php"

    local esc_pass
    esc_pass="$(printf '%s' "$root_pass" | sed "s/\\\\/\\\\\\\\/g; s/'/\\\\'/g")"

    # db_name='' so phpMyAdmin shows ALL databases (no only_db filter).
    # is_admin=true so list / revoke / etc. recognize this entry.
    cat > "$link_file" <<PHP
<?php return array (
  'path' => '${pma_path}',
  'slug' => '_admin',
  'domain' => 'ALL DATABASES (root)',
  'db_name' => '',
  'user' => 'root',
  'pass' => '${esc_pass}',
  'created' => ${created_ts},
  'expires' => ${expires_ts},
  'created_ip' => '${created_ip}',
  'is_admin' => true,
  'claimed_token' => '',
  'claimed_at' => 0,
  'claimed_ip' => '',
);
PHP
    chown "$PMA_USER:$PMA_USER" "$link_file"
    chmod 600 "$link_file"

    pma_render_nginx_snippet
    _pma_nginx_reload || {
        rm -f "$link_file"
        pma_render_nginx_snippet
        _pma_nginx_reload || true
        die "nginx reload failed — admin link rolled back"
    }

    local scheme="http"
    [[ -f "/etc/letsencrypt/live/${panel_domain}/fullchain.pem" ]] && scheme="https"
    [[ "$scheme" == "http" ]] \
        && log_warn "Panel has no SSL — root credentials will travel in plaintext. Run: mwp panel ssl"

    local url="${scheme}://${panel_domain}${pma_path}"
    local human_expiry
    human_expiry="$(date -d "@$expires_ts" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || printf '%s' "$expires_ts")"

    printf '\n%b  ⚠  ADMIN phpMyAdmin link — ROOT access to ALL databases%b\n' "$RED" "$NC"
    printf '  %s\n' "──────────────────────────────────────────────────────────"
    printf '  %s\n\n' "$url"
    printf '  Login as:   root  (sees every site DB)\n'
    printf '  Expires:    %s  (%sh)\n' "$human_expiry" "$ttl_hours"
    printf '  %bSingle-use.%b First browser to open it locks the link;\n' "$DIM" "$NC"
    printf '  %b           %b further browsers get HTTP 403.\n' "$DIM" "$NC"
    printf '  %bRevoke now: mwp db pma revoke-all%b\n\n' "$YELLOW" "$NC"
}

# ---------------------------------------------------------------------------
# pma_render_nginx_snippet — regenerate /etc/nginx/snippets/mwp-pma.conf
# from current link files. Idempotent. No nginx reload (caller decides).
# ---------------------------------------------------------------------------
pma_render_nginx_snippet() {
    : > "$PMA_NGINX_SNIPPET"
    {
        printf '# mwp phpMyAdmin — auto-generated, do not edit.\n'
        printf '# Regenerated on link create/revoke/sweep.\n\n'
    } > "$PMA_NGINX_SNIPPET"

    local link_file
    while IFS= read -r link_file; do
        [[ -z "$link_file" || ! -f "$link_file" ]] && continue
        local pma_path domain expires_ts expires_human
        pma_path="$(_pma_link_field "$link_file" path)"
        domain="$(_pma_link_field "$link_file" domain)"
        expires_ts="$(_pma_link_int_field "$link_file" expires)"
        [[ -z "$pma_path" ]] && continue
        expires_human="$(date -d "@${expires_ts:-0}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo unknown)"

        PMA_PATH="$pma_path" \
        DOMAIN="$domain" \
        EXPIRES_HUMAN="$expires_human" \
            render_template "$MWP_DIR/templates/nginx/pma-location.conf.tpl" \
            >> "$PMA_NGINX_SNIPPET"
        printf '\n' >> "$PMA_NGINX_SNIPPET"
    done < <(_pma_link_files)
    chmod 644 "$PMA_NGINX_SNIPPET"
}

# ---------------------------------------------------------------------------
# pma_list — show all active links
# ---------------------------------------------------------------------------
pma_list() {
    _pma_require_installed

    local count=0
    local files
    mapfile -t files < <(_pma_link_files)

    printf '\n%b  Active phpMyAdmin links%b\n' "$BOLD" "$NC"
    printf '  %s\n' "─────────────────────────────────────────────────────────────────────"
    printf '  %-28s %-10s %-19s %s\n' "DOMAIN" "STATUS" "EXPIRES" "PATH"
    printf '  %s\n' "─────────────────────────────────────────────────────────────────────"

    local f
    for f in "${files[@]}"; do
        [[ -z "$f" || ! -f "$f" ]] && continue
        local domain pma_path expires_ts claimed_token claimed_ip is_admin
        domain="$(_pma_link_field "$f" domain)"
        pma_path="$(_pma_link_field "$f" path)"
        expires_ts="$(_pma_link_int_field "$f" expires)"
        claimed_token="$(_pma_link_field "$f" claimed_token)"
        claimed_ip="$(_pma_link_field "$f" claimed_ip)"
        is_admin=0
        [[ "$(basename "$f")" == _admin-* ]] && is_admin=1

        local now status
        now="$(date +%s)"
        if [[ -n "$expires_ts" && "$now" -gt "$expires_ts" ]]; then
            status="expired"
        elif [[ -n "$claimed_token" ]]; then
            status="claimed"
        else
            status="unused"
        fi

        local exp_human
        exp_human="$(date -d "@${expires_ts:-0}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo unknown)"

        local color="$GREEN"
        [[ "$status" == "expired" ]] && color="$DIM"
        [[ "$status" == "claimed" ]] && color="$YELLOW"

        local label_color=""
        local label="$domain"
        if [[ $is_admin -eq 1 ]]; then
            label="ADMIN — all DBs (root)"
            label_color="$RED"
        fi

        printf '  %b%-28s%b %b%-10s%b %-19s %s\n' \
            "$label_color" "$(_trunc "$label" 28)" "$NC" \
            "$color" "$status" "$NC" "$exp_human" "$pma_path"
        [[ "$status" == "claimed" && -n "$claimed_ip" ]] \
            && printf '  %s%s%s\n' "$DIM" "    locked to: $claimed_ip" "$NC"
        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        printf '  %bNo active links. Create one: mwp db pma <domain>%b\n' "$DIM" "$NC"
    fi
    printf '\n  %b%d link(s) total%b\n\n' "$DIM" "$count" "$NC"
}

# ---------------------------------------------------------------------------
# pma_revoke <domain> — delete all links for one site
# ---------------------------------------------------------------------------
pma_revoke() {
    require_root
    local domain="${1:-}"
    [[ -z "$domain" ]] && die "Usage: mwp db pma revoke <domain>"
    _pma_require_installed

    local count=0 f
    while IFS= read -r f; do
        [[ -z "$f" || ! -f "$f" ]] && continue
        rm -f "$f" && count=$((count + 1))
    done < <(_pma_link_files "$domain")

    if [[ $count -eq 0 ]]; then
        log_info "No active links for $domain."
        return 0
    fi

    pma_render_nginx_snippet
    _pma_nginx_reload || true
    log_success "Revoked $count link(s) for $domain."
}

# Silent variant — used by site_delete hook (must not die or prompt)
pma_revoke_silent() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && return 0
    _pma_is_installed || return 0

    local count=0 f
    while IFS= read -r f; do
        [[ -z "$f" || ! -f "$f" ]] && continue
        rm -f "$f" && count=$((count + 1))
    done < <(_pma_link_files "$domain")

    if [[ $count -gt 0 ]]; then
        pma_render_nginx_snippet
        _pma_nginx_reload || true
        log_sub "Revoked $count phpMyAdmin link(s) for $domain"
    fi
}

pma_revoke_all() {
    require_root
    _pma_require_installed
    confirm "Revoke ALL active phpMyAdmin links?" || { log_info "Aborted."; return 0; }
    pma_revoke_all_silent
    log_success "All links revoked."
}

pma_revoke_all_silent() {
    rm -f "$PMA_LINKS_DIR"/*.php 2>/dev/null || true
    [[ -f "$PMA_NGINX_SNIPPET" ]] && pma_render_nginx_snippet
    _pma_nginx_reload || true
}

# ---------------------------------------------------------------------------
# pma_sweep_expired — cron entry point (runs every 5 min)
# ---------------------------------------------------------------------------
pma_sweep_expired() {
    _pma_is_installed || return 0
    local now removed=0 f expires_ts
    now="$(date +%s)"
    while IFS= read -r f; do
        [[ -z "$f" || ! -f "$f" ]] && continue
        expires_ts="$(_pma_link_int_field "$f" expires)"
        if [[ -n "$expires_ts" && "$now" -gt "$expires_ts" ]]; then
            rm -f "$f"
            removed=$((removed + 1))
        fi
    done < <(_pma_link_files)

    if [[ $removed -gt 0 ]]; then
        pma_render_nginx_snippet
        _pma_nginx_reload || true
        log_info "pma sweep: removed $removed expired link(s)"
    fi
}

# ---------------------------------------------------------------------------
# pma_status — install state + active link count
# ---------------------------------------------------------------------------
pma_status() {
    printf '\n%b  phpMyAdmin status%b\n' "$BOLD" "$NC"
    printf '  %s\n' "──────────────────────────────────"

    if ! _pma_is_installed; then
        printf '  Installed:  %bno%b\n' "$YELLOW" "$NC"
        printf '  Install:    mwp db pma install\n\n'
        return 0
    fi

    local installed_at php_ver fpm_svc panel_domain link_count
    installed_at="$(server_get "PMA_INSTALLED_AT")"
    php_ver="$(server_get "PMA_PHP_VERSION")"
    fpm_svc="php${php_ver}-fpm"
    panel_domain="$(server_get "PANEL_DOMAIN")"
    link_count=0
    local f
    while IFS= read -r f; do
        [[ -n "$f" && -f "$f" ]] && link_count=$((link_count + 1))
    done < <(_pma_link_files)

    local fpm_state="inactive" router_state="missing" snippet_state="missing"
    systemctl is-active --quiet "$fpm_svc" 2>/dev/null && fpm_state="active"
    [[ -f "$PMA_ROUTER_CONF" ]]   && router_state="present"
    [[ -f "$PMA_NGINX_SNIPPET" ]] && snippet_state="present"

    printf '  Installed:    %byes%b  (%s)\n' "$GREEN" "$NC" "$installed_at"
    printf '  PHP version:  %s  (%s: %s)\n' "$php_ver" "$fpm_svc" "$fpm_state"
    printf '  Panel host:   %s\n' "${panel_domain:-not configured}"
    printf '  Router:       %s\n' "$router_state"
    printf '  Nginx incl:   %s\n' "$snippet_state"
    printf '  Active links: %d\n' "$link_count"
    printf '\n  Generate link: mwp db pma <domain>\n'
    printf '  List links:    mwp db pma list\n\n'
}
