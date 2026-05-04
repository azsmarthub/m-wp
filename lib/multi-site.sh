#!/usr/bin/env bash
# lib/multi-site.sh — Site CRUD for mwp
# Orchestrates: user, dirs, DB, PHP pool, Nginx, WordPress, SSL, registry

[[ -n "${_MWP_SITE_LOADED:-}" ]] && return 0
_MWP_SITE_LOADED=1

# Lazy-load dependencies
_site_deps_loaded=0
_load_site_deps() {
    [[ $_site_deps_loaded -eq 1 ]] && return
    source "$MWP_DIR/lib/multi-nginx.sh"
    source "$MWP_DIR/lib/multi-php.sh"
    _site_deps_loaded=1
}

# ---------------------------------------------------------------------------
# site_create <domain>
# ---------------------------------------------------------------------------
site_create() {
    local domain="${1:-}"

    # --- Validate ---
    [[ -z "$domain" ]] && die "Usage: mwp site create <domain>"
    validate_domain "$domain" || die "Invalid domain: $domain"
    site_exists "$domain" && die "Site '$domain' already exists. Run: mwp site info $domain"

    _load_site_deps

    # Guard: ensure install.sh was run first
    [[ -f "$MWP_SERVER_CONF" ]] || die "Server not initialized. Run install.sh first."
    nginx_check_setup

    # Per-domain CF detection. The CF-IP map at /etc/nginx/conf.d/mwp-cf-realip.conf
    # is always loaded (installed by step_isolation in install.sh and refreshed
    # weekly by cron). Each vhost decides locally whether to enforce CF-only:
    #   - CF-proxied domain → vhost emits `if (!is_cf_source) return 444;`
    #   - direct-DNS domain → vhost is open to all sources
    # Both modes coexist on the same server, no operator choice required.
    if [[ -f "$MWP_DIR/lib/multi-cf.sh" ]]; then
        # shellcheck source=/dev/null
        source "$MWP_DIR/lib/multi-cf.sh"
        [[ -f "$CF_IPS_V4_FILE" ]] || cf_refresh
        local _cf_apex
        _cf_apex="$( set +o pipefail; dig +short A "$domain" 2>/dev/null \
                     | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -1 )"
        if [[ -n "$_cf_apex" ]] && is_cloudflare_ip "$_cf_apex"; then
            export CF_PROXIED="yes"
            export CF_GUARD="$(cf_guard_for_cf_proxied)"
            log_sub "Domain is CF-proxied (DNS → $_cf_apex) — vhost will reject non-CF source IPs."
        else
            export CF_PROXIED="no"
            export CF_GUARD="$(cf_guard_empty)"
            [[ -n "$_cf_apex" ]] \
                && log_sub "Domain is direct-DNS (→ $_cf_apex) — vhost open to all sources." \
                || log_sub "Domain DNS not resolved yet — vhost open to all sources (revisit if you CF-proxy later)."
        fi
    else
        export CF_GUARD=""
    fi

    # --- Derive variables ---
    local slug site_user web_root cache_path db_name db_user db_pass redis_db
    slug="$(domain_to_slug "$domain")"
    site_user="$slug"
    web_root="/home/${site_user}/${domain}"
    cache_path="/home/${site_user}/cache/fastcgi"

    # DB names: max 32 chars for MariaDB user/db
    db_name="wp_$(printf '%s' "$slug" | cut -c1-28)"
    db_user="$(printf '%s' "$db_name" | cut -c1-32)"
    db_pass="$(generate_password 24)"
    redis_db="$(redis_alloc_db "$domain")"

    # PHP version: use server default or 8.3
    local PHP_VERSION
    PHP_VERSION="$(server_get "DEFAULT_PHP")"
    PHP_VERSION="${PHP_VERSION:-8.3}"

    # Export for template rendering and sub-functions
    export DOMAIN="$domain"
    export SITE_USER="$site_user"
    export WEB_ROOT="$web_root"
    export CACHE_PATH="$cache_path"
    export PHP_VERSION
    export DB_NAME="$db_name"
    export DB_USER="$db_user"
    export DB_PASS="$db_pass"
    export REDIS_DB="$redis_db"

    log_info "Creating site: $domain"
    printf '  User:    %s\n' "$site_user"
    printf '  PHP:     %s\n' "$PHP_VERSION"
    printf '  WebRoot: %s\n' "$web_root"
    printf '  Redis:   DB %s\n' "$redis_db"
    printf '\n'

    local start_ts
    start_ts="$(date +%s)"
    local total=9

    log_step 1 $total "Creating system user + directories"
    _site_create_user

    log_step 2 $total "Setting up MariaDB database"
    _site_create_db

    log_step 3 $total "Creating PHP-FPM pool"
    php_create_pool "$domain"

    log_step 4 $total "Creating Nginx vhost"
    nginx_create_site "$domain"

    log_step 5 $total "Installing WordPress"
    _site_install_wordpress

    log_step 6 $total "Applying isolation hardening"
    source "$MWP_DIR/lib/multi-isolation.sh"
    isolation_site_apply "$site_user" "$web_root"

    # Register BEFORE SSL — nginx_enable_https() reads site config via site_get,
    # which would return empty values if the site isn't registered yet, producing
    # an invalid vhost (`root ;`) and breaking nginx -t. If SSL then fails the
    # site is still registered cleanly and the user can retry `mwp ssl issue`.
    log_step 7 $total "Registering site"
    registry_add "$domain"
    [[ -n "${CF_PROXIED:-}" ]] && site_set "$domain" "CF_PROXIED" "$CF_PROXIED"

    log_step 8 $total "Issuing SSL certificate"
    _site_issue_ssl_or_skip

    log_step 9 $total "Auto-retune FPM pools"
    source "$MWP_DIR/lib/multi-tuning.sh"
    tuning_retune_all

    local elapsed=$(( $(date +%s) - start_ts ))
    printf '\n%b✔ Site created in %ds%b\n' "$GREEN" "$elapsed" "$NC"
    _site_print_credentials
}

# ---------------------------------------------------------------------------
# Helpers for site_create
# ---------------------------------------------------------------------------
_site_create_user() {
    if ! id "$SITE_USER" &>/dev/null; then
        useradd --create-home --shell /usr/sbin/nologin "$SITE_USER"
        log_sub "User created: $SITE_USER"
    else
        log_sub "User already exists: $SITE_USER"
    fi

    mkdir -p "$WEB_ROOT" \
              "$CACHE_PATH" \
              "/home/${SITE_USER}/logs" \
              "/home/${SITE_USER}/backups" \
              "/home/${SITE_USER}/tmp"

    chown -R "${SITE_USER}:${SITE_USER}" "/home/${SITE_USER}"
    chmod 750 "/home/${SITE_USER}"

    # www-data needs read access for static files
    usermod -aG "$SITE_USER" www-data 2>/dev/null || true

    log_sub "Directories ready under /home/${SITE_USER}/"
}

_site_create_db() {
    local root_pass
    root_pass="$(server_get "DB_ROOT_PASS")"
    [[ -z "$root_pass" ]] && die "DB root password not found in server config. Was install.sh run?"

    mysql -u root -p"${root_pass}" 2>/dev/null <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    log_sub "Database '${DB_NAME}' created, user '${DB_USER}' granted access"
}

_site_install_wordpress() {
    # Ensure WP-CLI available
    command -v wp >/dev/null 2>&1 || die "WP-CLI not found. Run install.sh first."

    # Generate WP credentials — avoid "admin" (most targeted username).
    # Use a subshell with pipefail OFF; otherwise head closing the pipe sends
    # SIGPIPE to tr → pipeline rc=141 → caller's set -e exits site_create.
    local rand_suffix
    rand_suffix="$( set +o pipefail; LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c6 )"
    WP_ADMIN_USER="wpadm${rand_suffix}"
    WP_ADMIN_EMAIL="webmaster@${DOMAIN}"
    WP_ADMIN_PASS="$(generate_password 20)"

    local wp="sudo -u ${SITE_USER} wp --allow-root --path=${WEB_ROOT}"

    log_sub "Downloading WordPress core..."
    $wp core download --locale=en_US 2>&1 | grep -v Deprecated | grep -v Warning || true

    log_sub "Creating wp-config.php..."
    $wp config create \
        --dbname="$DB_NAME" \
        --dbuser="$DB_USER" \
        --dbpass="$DB_PASS" \
        --dbhost="localhost" \
        --dbprefix="wp_" \
        --skip-check 2>&1 | grep -v Deprecated || true

    # Redis config
    $wp config set WP_REDIS_SCHEME "unix"    2>&1 | grep -v Deprecated || true
    $wp config set WP_REDIS_PATH   "$(server_get REDIS_SOCK)" 2>&1 | grep -v Deprecated || true
    $wp config set WP_REDIS_DATABASE "$REDIS_DB" --raw 2>&1 | grep -v Deprecated || true
    $wp config set WP_CACHE_KEY_SALT "${DOMAIN}_" 2>&1 | grep -v Deprecated || true

    log_sub "Installing WordPress..."
    $wp core install \
        --url="http://${DOMAIN}" \
        --title="$DOMAIN" \
        --admin_user="$WP_ADMIN_USER" \
        --admin_email="$WP_ADMIN_EMAIL" \
        --admin_password="$WP_ADMIN_PASS" \
        --skip-email 2>&1 | grep -v Deprecated || true

    log_sub "Installing Redis Object Cache plugin..."
    $wp plugin install redis-cache --activate 2>&1 | grep -v Deprecated | grep -v Warning || true
    $wp redis enable 2>&1 | grep -v Deprecated || true

    # Permissions
    find "$WEB_ROOT" -type d -exec chmod 750 {} \;
    find "$WEB_ROOT" -type f -exec chmod 640 {} \;
    chmod 600 "${WEB_ROOT}/wp-config.php"
    chown -R "${SITE_USER}:${SITE_USER}" "$WEB_ROOT"

    # WP cron via system cron (disable built-in)
    $wp config set DISABLE_WP_CRON true --raw 2>&1 | grep -v Deprecated || true
    printf '# mwp: WP-Cron for %s\n*/5 * * * * %s wp --allow-root --path=%s cron event run --due-now > /dev/null 2>&1\n' \
        "$DOMAIN" "$SITE_USER" "$WEB_ROOT" > "/etc/cron.d/mwp-wpcron-$(domain_to_slug "$DOMAIN")"
    chmod 644 "/etc/cron.d/mwp-wpcron-$(domain_to_slug "$DOMAIN")"

    log_sub "WordPress installed at ${WEB_ROOT}"
}

_site_issue_ssl_or_skip() {
    # Smart wrapper in lib/multi-ssl.sh handles DNS detection + picks LE
    # (direct DNS) or self-signed (Cloudflare proxy) automatically.
    source "$MWP_DIR/lib/multi-ssl.sh"
    ssl_issue "$DOMAIN" || log_warn "SSL setup failed — site is up on HTTP only. Retry: mwp ssl issue $DOMAIN"
}

_site_print_credentials() {
    printf '\n'
    printf '%b  ══════════════════════════════════════%b\n' "$GREEN" "$NC"
    printf '%b  Site:      %b https://%s\n' "$BOLD" "$NC" "$DOMAIN"
    printf '%b  WP Admin:  %b https://%s/wp-admin\n' "$BOLD" "$NC" "$DOMAIN"
    printf '  Username:  %s\n' "$WP_ADMIN_USER"
    printf '  Password:  %b%s%b\n' "$BOLD" "$WP_ADMIN_PASS" "$NC"
    printf '  ──────────────────────────────────────\n'
    printf '  DB Name:   %s\n' "$DB_NAME"
    printf '  DB User:   %s\n' "$DB_USER"
    printf '  DB Pass:   %s\n' "$DB_PASS"
    printf '  Redis DB:  %s\n' "$REDIS_DB"
    printf '  ──────────────────────────────────────\n'
    printf '  PHP:       %s\n' "$PHP_VERSION"
    printf '  Web Root:  %s\n' "$WEB_ROOT"
    printf '  Cache:     %s\n' "$CACHE_PATH"
    printf '%b  ══════════════════════════════════════%b\n\n' "$GREEN" "$NC"
    printf '  %bManage:%b mwp site info %s\n\n' "$BOLD" "$NC" "$DOMAIN"
}

# ---------------------------------------------------------------------------
# site_delete <domain>
# ---------------------------------------------------------------------------
site_delete() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && die "Usage: mwp site delete <domain>"
    site_exists "$domain" || die "Site '$domain' not found."

    _load_site_deps

    # Load site config
    local site_user php_version web_root db_name db_user
    site_user="$(site_get "$domain" SITE_USER)"
    php_version="$(site_get "$domain" PHP_VERSION)"
    web_root="$(site_get "$domain" WEB_ROOT)"
    db_name="$(site_get "$domain" DB_NAME)"
    db_user="$(site_get "$domain" DB_USER)"
    local cron_slug
    cron_slug="$(domain_to_slug "$domain")"

    printf '\n%bDelete site: %s%b\n' "$RED" "$domain" "$NC"
    printf 'This will:\n'
    printf '  • Remove Nginx vhost\n'
    printf '  • Remove PHP-FPM pool\n'
    printf '  • Drop database: %s\n' "$db_name"
    printf '  • Delete Linux user + home: /home/%s\n' "$site_user"
    printf '  • Remove from registry\n\n'

    confirm "Type 'y' to confirm deletion of $domain" || { log_info "Aborted."; return 0; }

    log_info "Deleting site: $domain"

    # 1. Nginx
    nginx_delete_site "$domain" 2>/dev/null || true

    # 2. PHP-FPM pool
    php_delete_pool "$site_user" "$php_version" 2>/dev/null || true

    # 3. Database
    local root_pass
    root_pass="$(server_get "DB_ROOT_PASS")"
    if [[ -n "$root_pass" ]]; then
        mysql -u root -p"${root_pass}" 2>/dev/null <<SQL || true
DROP DATABASE IF EXISTS \`${db_name}\`;
DROP USER IF EXISTS '${db_user}'@'localhost';
FLUSH PRIVILEGES;
SQL
        log_sub "Database '${db_name}' dropped"
    fi

    # 4. System user + home
    if id "$site_user" &>/dev/null; then
        # Remove www-data from the site group first — otherwise userdel keeps
        # the group around (it has "other members") and the next site_create
        # for the same domain fails with "group already exists".
        gpasswd -d www-data "$site_user" 2>/dev/null || true
        userdel -r "$site_user" 2>/dev/null || true
        groupdel "$site_user" 2>/dev/null || true
        log_sub "User '${site_user}' and home deleted"
    fi

    # 5. SSL certificate
    certbot delete --cert-name "$domain" --non-interactive 2>/dev/null || true

    # 6. Cron jobs
    rm -f "/etc/cron.d/mwp-wpcron-${cron_slug}" 2>/dev/null || true

    # 6b. Revoke any active phpMyAdmin magic links for this site
    # Silent noop if pma not installed — link files would otherwise auto-login
    # to a DB user that no longer exists.
    if [[ -f "$MWP_DIR/lib/multi-pma.sh" ]]; then
        # shellcheck source=/dev/null
        source "$MWP_DIR/lib/multi-pma.sh"
        pma_revoke_silent "$domain" || true
    fi

    # 7. Registry
    registry_remove "$domain"

    # 8. Retune remaining sites
    local remaining
    remaining="$(site_count)"
    if [[ $remaining -gt 0 ]]; then
        source "$MWP_DIR/lib/multi-tuning.sh"
        tuning_retune_all
    fi

    log_success "Site '$domain' deleted."
}

# ---------------------------------------------------------------------------
# site_disable / site_enable
# ---------------------------------------------------------------------------
site_disable() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && die "Usage: mwp site disable <domain>"
    site_exists "$domain" || die "Site '$domain' not found."

    _load_site_deps
    nginx_disable_site "$domain"
    registry_set_status "$domain" "disabled"
    log_success "Site '$domain' disabled."
}

site_enable() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && die "Usage: mwp site enable <domain>"
    site_exists "$domain" || die "Site '$domain' not found."

    _load_site_deps
    nginx_enable_site "$domain"
    registry_set_status "$domain" "active"
    log_success "Site '$domain' enabled."
}

# ---------------------------------------------------------------------------
# site_magic_login <domain> [user_id=1]  →  one-time 24h auto-login URL
#
# Pattern ported from az-wp _wp_auto_login. Drops a tiny mu-plugin (~30
# lines) into wp-content/mu-plugins/ that handles the ?_mwp_login=<token>
# query param: validates token + expiry, sets auth cookie, deletes
# token (single-use), redirects to /wp-admin/.
#
# Why mu-plugin instead of regular plugin:
#   - Single-file drop, no install/activate step
#   - Auto-loaded by WP core (runs on every request)
#   - Invisible in admin Plugins list
#   - Removable by deleting the file
#
# Token lifecycle:
#   1. openssl rand -hex 32  (256-bit secret)
#   2. Saved to wp_options as `_mwp_magic_token` = "<token>:<expiry-ts>"
#   3. URL printed to operator
#   4. User clicks → mu-plugin validates + deletes option (one-shot)
#   5. wp_set_auth_cookie(<uid>) → redirect to /wp-admin/
#
# TTL default 86400s (24h). Single-use — once clicked, token gone.
# ---------------------------------------------------------------------------
site_magic_login() {
    local domain="${1:-}"
    local user_id="${2:-1}"
    [[ -z "$domain" ]] && die "Usage: mwp site login <domain> [user_id]"
    site_exists "$domain" || die "Site '$domain' not found."
    [[ "$user_id" =~ ^[0-9]+$ ]] || die "user_id must be a number (got: $user_id)"

    require_root

    local site_user web_root ssl_active scheme
    site_user="$(site_get "$domain" SITE_USER)"
    web_root="$(site_get "$domain" WEB_ROOT)"

    # Pick scheme — prefer https if cert exists, else http
    if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" \
       || -f "/etc/mwp/ssl/${domain}/fullchain.pem" ]]; then
        scheme="https"
    else
        scheme="http"
    fi

    local wp="sudo -u ${site_user} wp --allow-root --path=${web_root}"

    # Verify the user actually exists on this site (avoid "click → wp_die")
    if ! $wp user get "$user_id" --field=ID >/dev/null 2>&1; then
        die "No WordPress user with ID=$user_id on $domain.
   List users:  sudo -u $site_user wp user list --path=$web_root"
    fi

    # Generate token + expiry (24h)
    local token expiry
    token="$(openssl rand -hex 32)"
    expiry="$(date -d '+24 hours' '+%s')"

    # Save to wp_options
    $wp option update _mwp_magic_token "${token}:${expiry}:${user_id}" >/dev/null 2>&1 \
        || die "Failed to write WP option (DB issue?)"

    # Drop mu-plugin if not present.
    # WP loads /wp-content/mu-plugins/*.php automatically without activation.
    # File is invisible in admin → admin can't accidentally deactivate it.
    local mu_dir="${web_root}/wp-content/mu-plugins"
    local mu_file="${mu_dir}/mwp-autologin.php"
    if [[ ! -f "$mu_file" ]]; then
        mkdir -p "$mu_dir"
        cat > "$mu_file" <<'MUPHP'
<?php
/**
 * Plugin Name: mwp Auto-Login
 * Description: One-time 24h auto-login link generator (CLI: mwp site login).
 *
 * Listens for ?_mwp_login=<token>. Token is single-use: validated then
 * deleted from wp_options. Generated by `mwp site login <domain>`.
 */
add_action('init', function () {
    if (empty($_GET['_mwp_login'])) return;
    $token = sanitize_text_field($_GET['_mwp_login']);
    $stored = get_option('_mwp_magic_token', '');
    if (empty($stored)) return;

    $parts = explode(':', $stored, 3);
    if (count($parts) < 2) return;
    list($valid_token, $expiry) = [$parts[0], (int)$parts[1]];
    $user_id = isset($parts[2]) ? (int)$parts[2] : 1;

    if (!hash_equals($valid_token, $token)) return;

    // Always invalidate after a click attempt — failure or success
    delete_option('_mwp_magic_token');

    if (time() > $expiry) {
        wp_die('mwp magic-login link expired. Generate a new one: <code>mwp site login</code>');
    }

    wp_set_current_user($user_id);
    wp_set_auth_cookie($user_id, true);
    wp_safe_redirect(admin_url());
    exit;
}, 1);
MUPHP
        chown "${site_user}:${site_user}" "$mu_file"
        chmod 644 "$mu_file"
        log_sub "mu-plugin installed: ${mu_file}"
    fi

    local url="${scheme}://${domain}/?_mwp_login=${token}"
    local human_expiry
    human_expiry="$(date -d "@$expiry" '+%Y-%m-%d %H:%M %Z')"

    printf '\n%b  Magic-login URL for %s%b\n' "$BOLD" "$domain" "$NC"
    printf '  %s\n' "──────────────────────────────────────────────────────────"
    printf '  %s\n\n' "$url"
    printf '  User ID:    %s\n' "$user_id"
    printf '  Expires:    %s  (24h)\n' "$human_expiry"
    printf '  %bSingle-use.%b Click → /wp-admin/. Re-run command for new URL.\n\n' "$DIM" "$NC"
}
