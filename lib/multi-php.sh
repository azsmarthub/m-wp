#!/usr/bin/env bash
# lib/multi-php.sh — Multi-version PHP management for mwp

[[ -n "${_MWP_PHP_LOADED:-}" ]] && return 0
_MWP_PHP_LOADED=1

MWP_PHP_EXTENSIONS="fpm mysql redis curl gd mbstring xml zip intl bcmath imagick soap"

# ---------------------------------------------------------------------------
# List installed PHP versions
# ---------------------------------------------------------------------------
php_list_versions() {
    printf '\n%bInstalled PHP versions:%b\n' "$BOLD" "$NC"
    local found=0
    local ver
    for ver in 8.1 8.2 8.3 8.4; do
        if command -v "php${ver}" >/dev/null 2>&1; then
            local fpm_status="inactive"
            systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null && fpm_status="active"
            printf '  %bphp%s%b  FPM: %s\n' "$GREEN" "$ver" "$NC" "$fpm_status"
            found=1
        fi
    done
    [[ $found -eq 0 ]] && printf '  %bNone found%b\n' "$DIM" "$NC"
    printf '\n'
}

# ---------------------------------------------------------------------------
# Install a PHP version + standard extensions
# ---------------------------------------------------------------------------
php_install_version() {
    local version="${1:-}"
    [[ -z "$version" ]] && die "Usage: mwp php install <version> (e.g. 8.2)"

    # Validate
    case "$version" in
        8.1|8.2|8.3|8.4) ;;
        *) die "Unsupported PHP version: $version. Supported: 8.1 8.2 8.3 8.4" ;;
    esac

    if command -v "php${version}" >/dev/null 2>&1; then
        log_info "PHP ${version} is already installed."
        return 0
    fi

    log_info "Installing PHP ${version}..."

    # Ensure ondrej/php PPA
    if ! grep -rq "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        log_sub "Adding PHP PPA (ondrej/php)..."
        apt_install software-properties-common
        add-apt-repository -y ppa:ondrej/php 2>&1 | tail -2 || true
        apt-get update -qq 2>&1 | tail -1 || true
    fi

    local pkgs=()
    local ext
    for ext in $MWP_PHP_EXTENSIONS; do
        pkgs+=("php${version}-${ext}")
    done

    apt_install "${pkgs[@]}"
    systemctl enable "php${version}-fpm"
    systemctl start  "php${version}-fpm"

    # Basic OPcache config
    local ini_dir="/etc/php/${version}/fpm/conf.d"
    cat > "${ini_dir}/99-mwp-opcache.ini" <<INI
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.revalidate_freq=2
opcache.save_comments=1
INI

    systemctl restart "php${version}-fpm"
    log_success "PHP ${version} installed and running."
}

# ---------------------------------------------------------------------------
# Create isolated FPM pool for a site
# Expects: DOMAIN, SITE_USER, PHP_VERSION, WEB_ROOT (from env / caller)
# ---------------------------------------------------------------------------
php_create_pool() {
    local domain="$1"
    local pool_dir="/etc/php/${PHP_VERSION}/fpm/pool.d"
    local pool_file="${pool_dir}/${SITE_USER}.conf"

    [[ -d "$pool_dir" ]] || die "PHP ${PHP_VERSION} not installed (pool dir missing: $pool_dir)"

    # Calculate pm.max_children based on available RAM and site count
    local ram_mb site_count pm_children
    ram_mb="$(detect_ram_mb)"
    site_count="$(site_count)"
    site_count=$(( site_count + 1 ))   # include the site being created
    pm_children="$(php_calc_pm_children "$ram_mb" "$site_count")"

    PHP_MEMORY_LIMIT="$(php_calc_memory_limit "$ram_mb" "$site_count")"
    PM_MAX_CHILDREN="$pm_children"
    GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"

    render_template "$MWP_DIR/templates/php/multi-pool.conf.tpl" > "$pool_file"

    systemctl restart "php${PHP_VERSION}-fpm"
    log_sub "PHP-FPM pool created: $pool_file (pm.max_children=${pm_children})"
}

# ---------------------------------------------------------------------------
# Remove FPM pool for a site
# ---------------------------------------------------------------------------
php_delete_pool() {
    local site_user="$1" php_version="$2"
    local pool_file="/etc/php/${php_version}/fpm/pool.d/${site_user}.conf"

    rm -f "$pool_file"
    systemctl reload "php${php_version}-fpm" 2>/dev/null || true
    log_sub "PHP-FPM pool removed: $pool_file"
}

# ---------------------------------------------------------------------------
# Switch PHP version for a site
# ---------------------------------------------------------------------------
php_switch_site() {
    local domain="${1:-}" new_version="${2:-}"
    [[ -z "$domain" || -z "$new_version" ]] && die "Usage: mwp php switch <domain> <version>"

    site_exists "$domain" || die "Site '$domain' not found."

    case "$new_version" in
        8.1|8.2|8.3|8.4) ;;
        *) die "Unsupported PHP version: $new_version" ;;
    esac

    command -v "php${new_version}" >/dev/null 2>&1 || \
        die "PHP ${new_version} not installed. Run: mwp php install ${new_version}"

    local old_version site_user web_root cache_path
    old_version="$(site_get "$domain" PHP_VERSION)"
    site_user="$(site_get "$domain" SITE_USER)"
    web_root="$(site_get "$domain" WEB_ROOT)"
    cache_path="$(site_get "$domain" CACHE_PATH)"

    [[ "$old_version" == "$new_version" ]] && { log_info "PHP version unchanged: ${new_version}"; return 0; }

    log_info "Switching $domain: PHP ${old_version} → ${new_version}"

    # Remove old pool
    php_delete_pool "$site_user" "$old_version"

    # Export vars needed by php_create_pool
    DOMAIN="$domain"
    SITE_USER="$site_user"
    PHP_VERSION="$new_version"
    WEB_ROOT="$web_root"
    CACHE_PATH="$cache_path"

    # Create new pool
    php_create_pool "$domain"

    # Update Nginx vhost to use new socket
    local nginx_conf="/etc/nginx/sites-available/${domain}.conf"
    if [[ -f "$nginx_conf" ]]; then
        sed -i "s|php${old_version}-fpm-${site_user}\.sock|php${new_version}-fpm-${site_user}.sock|g" "$nginx_conf"
        nginx_reload
        log_sub "Nginx updated to PHP ${new_version} socket"
    fi

    # Update registry
    site_set "$domain" "PHP_VERSION" "$new_version"

    log_success "PHP switched to ${new_version} for ${domain}"
}

# ---------------------------------------------------------------------------
# Calculate pm.max_children
# Simple formula: (available RAM - 256MB reserve) / site_count / 30MB per child
# ---------------------------------------------------------------------------
php_calc_pm_children() {
    local ram_mb="$1" site_count="$2"
    local available=$(( ram_mb - 256 ))
    [[ $available -lt 128 ]] && available=128
    local per_site=$(( available / site_count ))
    local children=$(( per_site / 30 ))
    [[ $children -lt 2 ]] && children=2
    [[ $children -gt 12 ]] && children=12
    printf '%d' "$children"
}

# ---------------------------------------------------------------------------
# Calculate memory_limit per site
# ---------------------------------------------------------------------------
php_calc_memory_limit() {
    local ram_mb="$1" site_count="$2"
    local limit=$(( (ram_mb - 256) / site_count ))
    [[ $limit -lt 64 ]] && limit=64
    [[ $limit -gt 512 ]] && limit=512
    printf '%d' "$limit"
}
