#!/usr/bin/env bash
# multi/install.sh — mwp server setup (run once on fresh VPS)
# Sets up: Nginx, PHP, MariaDB, Redis, WP-CLI, UFW, Fail2ban
# Usage: bash install.sh

# When stdin is not a TTY (e.g. `curl | bash` from a real shell session),
# try to grab the user's terminal back so prompts still work. In a fully
# non-interactive context (SSH BatchMode, systemd unit, CI) /dev/tty doesn't
# exist — we skip silently. For scripted installs, set MWP_NONINTERACTIVE=1
# explicitly: that bypasses both prompts (panel URL + start-confirm) without
# depending on TTY tricks.
if [[ "${MWP_NONINTERACTIVE:-0}" != "1" && ! -t 0 ]]; then
    exec 0</dev/tty 2>/dev/null || true
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MWP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export MWP_DIR

source "$MWP_DIR/lib/common.sh"
trap 'trap_error $LINENO "$BASH_COMMAND"' ERR

mwp_init
require_root

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
print_banner() {
    printf '\n'
    printf '═══════════════════════════════════════\n'
    printf '   mwp Server Setup v%s\n' "$MWP_VERSION"
    printf '   Multi-site WordPress Stack\n'
    printf '═══════════════════════════════════════\n'
    printf '\n'
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight_checks() {
    local ok=1

    # OS check — Ubuntu 24.04 only supported
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        case "${ID:-}" in
            ubuntu)
                case "${VERSION_ID:-}" in
                    24.04) log_info "OS: Ubuntu ${VERSION_ID} ✔" ;;
                    *) log_warn "Unsupported Ubuntu version: $VERSION_ID (requires: 24.04 LTS)" ;;
                esac
                ;;
            *) log_warn "Unsupported OS: ${PRETTY_NAME:-unknown} (requires Ubuntu 24.04 LTS)" ;;
        esac
    fi

    # RAM — warn only, do not abort (1GB is enough to install, tight for 3+ sites)
    local ram_mb
    ram_mb="$(detect_ram_mb)"
    if [[ $ram_mb -lt 1024 ]]; then
        log_warn "RAM: ${ram_mb}MB — tight. Recommended: 1GB min (2GB+ for 3+ sites)"
    else
        log_info "RAM: ${ram_mb}MB ✔"
    fi

    # Disk
    local disk_gb
    disk_gb="$(df -BG / | awk 'NR==2 {gsub("G",""); print $4}')"
    if [[ ${disk_gb:-0} -lt 10 ]]; then
        log_warn "Disk: ${disk_gb}GB free — minimum 10GB recommended"
    else
        log_info "Disk: ${disk_gb}GB free ✔"
    fi

    # Already installed?
    if [[ -f "$MWP_SERVER_CONF" ]]; then
        log_warn "mwp server config already exists at $MWP_SERVER_CONF"
        log_warn "Run 'mwp status' to check current state."
        confirm "Re-run setup anyway?" || exit 0
    fi
}

# ---------------------------------------------------------------------------
# Step runner
# ---------------------------------------------------------------------------
run_step() {
    local num="$1" total="$2" desc="$3" func="$4"
    local start_ts end_ts elapsed

    log_step "$num" "$total" "$desc"
    start_ts="$(date +%s)"
    "$func"
    end_ts="$(date +%s)"
    elapsed=$(( end_ts - start_ts ))
    log_success "$desc done (${elapsed}s)"
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
step_system_prep() {
    timedatectl set-timezone UTC 2>/dev/null || ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    apt_wait
    apt-get update -qq 2>&1 | tail -1 || true
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q 2>&1 | \
        grep -E "^(Get|Fetched|[0-9]+ upgraded)" | tail -3 || true
    # dnsutils: dig — dùng cho DNS check khi issue SSL
    apt_install curl wget gnupg software-properties-common unzip git bc \
        htop ncdu logrotate apt-transport-https ca-certificates lsb-release dnsutils rsync

    # Swap (if not exists) — always 1GB regardless of RAM
    if ! swapon --show | grep -q '/'; then
        local swap_mb=1024
        log_sub "Creating ${swap_mb}MB swap..."
        fallocate -l "${swap_mb}M" /swapfile 2>/dev/null || \
            dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=none
        chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
        grep -q '/swapfile' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
    fi
}

step_nginx() {
    if ! command -v nginx >/dev/null 2>&1; then
        log_sub "Adding Nginx mainline repo..."
        curl -fsSL https://nginx.org/keys/nginx_signing.key | \
            gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
        local codename
        codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
        printf 'deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/ubuntu %s nginx\n' \
            "$codename" > /etc/apt/sources.list.d/nginx.list
        printf 'Package: *\nPin: origin nginx.org\nPin-Priority: 900\n' > /etc/apt/preferences.d/99nginx
        apt-get update -qq 2>&1 | tail -1 || true
        apt_install nginx
    fi

    # --- Server-level Nginx config for multi-site ---
    local ram_mb cpu_cores
    ram_mb="$(detect_ram_mb)"
    cpu_cores="$(detect_cpu_cores)"

    # worker_connections: 1024 per core, min 1024
    local worker_conn=$(( cpu_cores * 1024 ))
    [[ $worker_conn -lt 1024 ]] && worker_conn=1024

    # worker_rlimit_nofile must be >= worker_connections * 2 to avoid
    # "worker_connections exceed open file resource limit" warning.
    local worker_rlimit=$(( worker_conn * 2 ))
    [[ $worker_rlimit -lt 8192 ]] && worker_rlimit=8192

    cat > /etc/nginx/nginx.conf <<NGINXCONF
user www-data;
worker_processes auto;
worker_rlimit_nofile ${worker_rlimit};
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections ${worker_conn};
    multi_accept on;
    use epoll;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Multi-domain: increase hash bucket size
    server_names_hash_bucket_size 128;
    server_names_hash_max_size 512;

    # Performance
    sendfile           on;
    tcp_nopush         on;
    tcp_nodelay        on;
    keepalive_timeout  65;
    keepalive_requests 100;
    types_hash_max_size 2048;

    # Security — hide version
    server_tokens off;

    # Buffer tuning
    client_max_body_size     64M;
    client_body_buffer_size  128k;
    large_client_header_buffers 4 16k;

    # FastCGI cache key (per-site cache zones declared in vhosts)
    fastcgi_cache_key "\$scheme\$request_method\$host\$request_uri";

    # Gzip (global)
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_types
        text/plain text/css text/xml text/javascript
        application/json application/javascript application/xml
        application/rss+xml image/svg+xml;

    # Logging
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" cache:\$upstream_cache_status';
    access_log /var/log/nginx/access.log main;

    # Include per-site configs
    include /etc/nginx/sites-enabled/*.conf;
}
NGINXCONF

    # Setup sites directories
    mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

    # Remove default site (conflicts with our multi-site setup)
    rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null || true

    nginx -t 2>/dev/null || die "Nginx config test failed after setup"
    systemctl enable nginx
    systemctl restart nginx
    log_sub "Nginx $(nginx -v 2>&1 | grep -o '[0-9.]*') ready (multi-site config applied)"
}

# ---------------------------------------------------------------------------
# Try ondrej/php PPA via Launchpad. Returns 0 if package php<ver>-cli becomes
# available, 1 otherwise. Cleans up after itself on failure so a later
# fallback (Sury, native) doesn't see stale apt sources.
# ---------------------------------------------------------------------------
_step_php_try_ondrej_ppa() {
    local want="$1"
    log_sub "Adding PHP PPA (ondrej/php on Launchpad)..."
    apt_install software-properties-common
    if ! add-apt-repository -y ppa:ondrej/php 2>&1 | tail -2; then
        log_sub "Launchpad PPA add failed."
        rm -f /etc/apt/sources.list.d/ondrej-ubuntu-php-*.{list,sources} 2>/dev/null
        return 1
    fi
    apt-get update -qq 2>&1 | tail -3 || true
    if apt-cache policy "php${want}-cli" 2>/dev/null | grep -q "Candidate: [0-9]"; then
        log_sub "Launchpad PPA active — php${want} available."
        return 0
    fi
    log_sub "Launchpad PPA added but php${want} not visible (CDN flaky?)."
    rm -f /etc/apt/sources.list.d/ondrej-ubuntu-php-*.{list,sources} 2>/dev/null
    apt-get update -qq 2>&1 | tail -1 || true
    return 1
}

# ---------------------------------------------------------------------------
# Fallback: same package set, mirrored at packages.sury.org (Fastly CDN).
# Same maintainer (Ondřej Surý). Returns 0 if php<ver>-cli becomes available.
# ---------------------------------------------------------------------------
_step_php_try_sury() {
    local want="$1"
    log_sub "Falling back to packages.sury.org..."
    install -d -m 0755 /etc/apt/keyrings
    if ! curl -fsSL --max-time 10 https://packages.sury.org/php/apt.gpg \
            -o /etc/apt/keyrings/sury-php.gpg; then
        log_sub "Cannot reach packages.sury.org for the GPG key."
        return 1
    fi
    chmod 644 /etc/apt/keyrings/sury-php.gpg
    cat > /etc/apt/sources.list.d/sury-php.list <<SURY
deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ \
$( . /etc/os-release && echo "${VERSION_CODENAME}" ) main
SURY
    if ! apt-get update -qq 2>&1 | tail -3 | grep -qiE "sury|http"; then
        :
    fi
    if apt-cache policy "php${want}-cli" 2>/dev/null | grep -q "Candidate: [0-9]"; then
        log_sub "sury.org active — php${want} available."
        return 0
    fi
    log_sub "sury.org added but php${want} not visible (Fastly edge block?)."
    rm -f /etc/apt/sources.list.d/sury-php.list /etc/apt/keyrings/sury-php.gpg
    apt-get update -qq 2>&1 | tail -1 || true
    return 1
}

step_php() {
    # Preferred PHP version (latest stable from ondrej PPA). If neither
    # Launchpad nor sury.org is reachable, fall back to whatever ship in
    # Ubuntu noble's main repo (currently php8.3) so the install still
    # completes — proven necessary on 2026-05-01 when both Launchpad and
    # Sury were edge-blocked from a Contabo VPS for hours.
    local default_php="8.5"

    if ! command -v php >/dev/null 2>&1; then
        if _step_php_try_ondrej_ppa "$default_php"; then
            : # PPA works — keep default_php="8.5"
        elif _step_php_try_sury "$default_php"; then
            :
        else
            log_warn "Both ondrej PPA (Launchpad) and packages.sury.org are unreachable."
            log_warn "Falling back to Ubuntu native PHP 8.3 (php8.5 will be missing)."
            default_php="8.3"
        fi
    fi

    log_sub "Installing PHP ${default_php} + extensions..."
    apt_install \
        "php${default_php}-fpm" \
        "php${default_php}-cli" \
        "php${default_php}-mysql" \
        "php${default_php}-redis" \
        "php${default_php}-curl" \
        "php${default_php}-gd" \
        "php${default_php}-mbstring" \
        "php${default_php}-xml" \
        "php${default_php}-zip" \
        "php${default_php}-intl" \
        "php${default_php}-bcmath" \
        "php${default_php}-imagick" \
        "php${default_php}-soap"

    # Disable default www pool (runs as www-data, not isolated)
    local default_pool="/etc/php/${default_php}/fpm/pool.d/www.conf"
    if [[ -f "$default_pool" ]]; then
        mv "$default_pool" "${default_pool}.disabled"
        log_sub "Default www pool disabled (not isolated)"
    fi

    # Placeholder pool — php-fpm refuses to start with zero pools.
    # This pool is minimal (1 child, ondemand, never reached by any vhost)
    # and gets removed automatically once the first real site pool exists.
    local placeholder_pool="/etc/php/${default_php}/fpm/pool.d/_placeholder.conf"
    if ! ls /etc/php/${default_php}/fpm/pool.d/*.conf 2>/dev/null | grep -qv _placeholder; then
        cat > "$placeholder_pool" <<PLACEHOLDER
; mwp placeholder pool — required for php-fpm to start before any site exists.
; Removed automatically when the first real per-site pool is created.
[_placeholder]
user = nobody
group = nogroup
listen = /run/php/_mwp_placeholder.sock
listen.owner = nobody
listen.group = nogroup
listen.mode = 0600
pm = ondemand
pm.max_children = 1
pm.process_idle_timeout = 10s
pm.max_requests = 100
PLACEHOLDER
        log_sub "Placeholder pool created (will be removed on first site create)"
    fi

    # Global PHP-FPM config: logging
    sed -i 's|^;error_log =.*|error_log = /var/log/mwp/php-fpm.log|' \
        "/etc/php/${default_php}/fpm/php-fpm.conf" 2>/dev/null || true

    # OPcache global config
    cat > "/etc/php/${default_php}/fpm/conf.d/99-mwp-opcache.ini" <<INI
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.revalidate_freq=2
opcache.save_comments=1
INI

    systemctl enable "php${default_php}-fpm"
    systemctl restart "php${default_php}-fpm"
    server_set "DEFAULT_PHP" "$default_php"
    log_sub "PHP ${default_php} ready (default www pool disabled)"
}

step_mariadb() {
    if ! command -v mariadb >/dev/null 2>&1; then
        log_sub "Adding MariaDB 11.4 LTS official repo..."
        curl -fsSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup \
            | bash -s -- --mariadb-server-version="mariadb-11.4" 2>&1 | tail -3 || true
        apt-get update -qq 2>&1 | tail -1 || true
        log_sub "Installing MariaDB 11.4..."
        apt_install mariadb-server mariadb-client
    fi
    systemctl enable mariadb

    # Secure install — skip if root pass already set (idempotent)
    local root_pass
    root_pass="$(server_get "DB_ROOT_PASS" 2>/dev/null)"
    if [[ -n "$root_pass" ]]; then
        log_sub "MariaDB already secured (root pass exists), skipping."
    else
        root_pass="$(generate_password 32)"
    fi
    mysql -u root 2>/dev/null <<SQL || true
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${root_pass}');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

    server_set "DB_ROOT_PASS" "$root_pass"

    # Basic tuning
    local ram_mb
    ram_mb="$(detect_ram_mb)"
    local innodb_mb=$(( ram_mb / 4 ))
    [[ $innodb_mb -lt 64 ]] && innodb_mb=64

    cat > /etc/mysql/mariadb.conf.d/99-mwp.cnf <<CNF
[mysqld]
innodb_buffer_pool_size = ${innodb_mb}M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
query_cache_type = 0
max_connections = 50
wait_timeout = 300
interactive_timeout = 300
CNF
    systemctl restart mariadb
    log_sub "MariaDB ready (InnoDB buffer: ${innodb_mb}MB)"
}

step_redis() {
    if ! command -v redis-server >/dev/null 2>&1; then
        apt_install redis-server
    fi

    local ram_mb
    ram_mb="$(detect_ram_mb)"
    local redis_mb=$(( ram_mb / 8 ))
    [[ $redis_mb -lt 32 ]] && redis_mb=32

    # Unix socket + memory limit
    sed -i 's|^# *unixsocket .*|unixsocket /run/redis/redis-server.sock|' /etc/redis/redis.conf 2>/dev/null || true
    sed -i 's|^# *unixsocketperm .*|unixsocketperm 777|' /etc/redis/redis.conf 2>/dev/null || true
    grep -q "^unixsocket " /etc/redis/redis.conf || \
        printf 'unixsocket /run/redis/redis-server.sock\nunixsocketperm 777\n' >> /etc/redis/redis.conf
    sed -i "s|^# *maxmemory .*|maxmemory ${redis_mb}mb|" /etc/redis/redis.conf 2>/dev/null || true
    grep -q "^maxmemory " /etc/redis/redis.conf || printf 'maxmemory %smb\n' "$redis_mb" >> /etc/redis/redis.conf
    grep -q "^maxmemory-policy" /etc/redis/redis.conf || printf 'maxmemory-policy allkeys-lru\n' >> /etc/redis/redis.conf

    mkdir -p /run/redis && chown redis:redis /run/redis 2>/dev/null || true
    systemctl enable redis-server && systemctl restart redis-server

    server_set "REDIS_SOCK" "/run/redis/redis-server.sock"
    log_sub "Redis ready (maxmem: ${redis_mb}MB)"
}

step_wpcli() {
    if ! command -v wp >/dev/null 2>&1; then
        log_sub "Installing WP-CLI..."
        curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
            -o /usr/local/bin/wp
        chmod +x /usr/local/bin/wp
    fi
    log_sub "WP-CLI $(wp --allow-root --version 2>/dev/null | head -1) ready"
}

step_certbot() {
    if ! command -v certbot >/dev/null 2>&1; then
        log_sub "Installing Certbot..."
        apt_install certbot python3-certbot-nginx
    fi
    log_sub "Certbot ready"
}

step_firewall() {
    # UFW
    if ! command -v ufw >/dev/null 2>&1; then
        apt_install ufw
    fi
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw allow 22/tcp  >/dev/null 2>&1   # SSH
    ufw allow 80/tcp  >/dev/null 2>&1   # HTTP
    ufw allow 443/tcp >/dev/null 2>&1   # HTTPS
    # NOTE: don't use 'Nginx Full' app profile — it's only registered when
    # nginx is installed from Ubuntu's repo, not from nginx.org mainline.
    ufw --force enable >/dev/null 2>&1
    log_sub "UFW enabled (22/80/443 tcp)"

    # Fail2ban
    apt_install fail2ban
    cat > /etc/fail2ban/jail.local <<F2B
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled  = true
F2B
    systemctl enable fail2ban && systemctl restart fail2ban
    log_sub "Fail2ban ready"
}

step_isolation() {
    source "$MWP_DIR/lib/multi-isolation.sh"
    isolation_global_apply
}

# ---------------------------------------------------------------------------
# Auto security updates — apply Ubuntu security patches without manual touch.
# Critical for landing kernel CVE fixes (e.g. CVE-2026-31431 Copy Fail) and
# nginx/openssl/php emergency patches without operator intervention.
#
# Reboot at 04:00 if a kernel patch requires it. WithUsers=false means an
# admin SSH session blocks the reboot — they'll see the pending-reboot flag
# in MOTD and reboot manually instead. Acceptable: the most common case is
# nobody logged in at 4am, which reboots cleanly.
# ---------------------------------------------------------------------------
step_auto_security_updates() {
    apt_install unattended-upgrades apt-listchanges

    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AUTOUP'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTOUP

    cat > /etc/apt/apt.conf.d/52unattended-upgrades-mwp <<'CONF'
# mwp — auto-apply security updates only (not feature upgrades)
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {};
Unattended-Upgrade::DevRelease "auto";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Mail "";
CONF

    systemctl enable unattended-upgrades >/dev/null 2>&1 || true
    systemctl restart unattended-upgrades >/dev/null 2>&1 || true
    log_sub "Security updates: auto-apply daily, reboot 04:00 if kernel patched"
}

# Phase 1: collect input only (called BEFORE nginx is installed)
step_panel_url_collect() {
    local panel_domain=""
    printf '\n%b  Panel URL setup (optional)%b\n' "$BOLD" "$NC"
    printf '  This sets a dedicated hostname for the mwp web UI (future).\n'
    printf '  Example: sv1.yourdomain.com  →  https://sv1.yourdomain.com\n'
    printf '  Press ENTER to skip.\n\n'
    printf '  Panel hostname: '
    read -r panel_domain

    if [[ -n "$panel_domain" ]]; then
        if validate_domain "$panel_domain"; then
            server_set "PANEL_DOMAIN" "$panel_domain"
            log_sub "Panel hostname saved: $panel_domain (vhost will be created after Nginx install)"
        else
            log_warn "Invalid domain — skipping panel URL setup."
        fi
    fi
}

# Phase 2: render vhost (called AFTER nginx is installed)
step_panel_url_apply() {
    local panel_domain
    panel_domain="$(server_get "PANEL_DOMAIN")"
    [[ -z "$panel_domain" ]] && { log_sub "Panel URL skipped — run 'mwp panel setup' later."; return 0; }

    local server_ip
    server_ip="$(detect_ip)"

    # Create placeholder web root
    mkdir -p /var/www/mwp-panel
    cat > /var/www/mwp-panel/index.html <<HTML
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><title>mwp Panel</title>
<style>body{font-family:monospace;background:#0f0f0f;color:#e0e0e0;display:flex;
align-items:center;justify-content:center;height:100vh;margin:0;}
.box{text-align:center;padding:2rem;border:1px solid #333;border-radius:8px;}
h1{color:#4ade80;font-size:1.5rem;}p{color:#888;}</style></head>
<body><div class="box">
<h1>mwp Panel</h1>
<p>Server: ${server_ip}</p>
<p>Web UI coming soon. Use <code>mwp</code> CLI in the meantime.</p>
</div></body></html>
HTML

    # Create Nginx vhost for panel domain
    local panel_conf="/etc/nginx/sites-available/mwp-panel.conf"
    PANEL_DOMAIN="$panel_domain" \
    GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S')" \
    render_template "$MWP_DIR/templates/nginx/panel-placeholder.conf.tpl" > "$panel_conf"

    ln -sf "$panel_conf" /etc/nginx/sites-enabled/mwp-panel.conf
    nginx -t 2>/dev/null && systemctl reload nginx
    log_success "Panel URL configured: http://${panel_domain}"
    log_sub "Issue SSL later: mwp ssl issue ${panel_domain}"
}

step_cli() {
    ln -sf "$SCRIPT_DIR/menu.sh" /usr/local/bin/mwp
    chmod +x "$SCRIPT_DIR/menu.sh"

    server_set "MWP_DIR" "$MWP_DIR"
    server_set "INSTALLED_AT" "$(date '+%Y-%m-%d %H:%M:%S')"
    server_set "SERVER_IP" "$(detect_ip)"

    log_sub "mwp CLI installed at /usr/local/bin/mwp"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    local start_time="$1"
    local elapsed=$(( $(date +%s) - start_time ))

    printf '\n%b═══════════════════════════════════════%b\n' "$GREEN" "$NC"
    printf '%b  Server setup complete! (%dm %ds)%b\n' "$GREEN" "$((elapsed/60))" "$((elapsed%60))" "$NC"
    printf '%b═══════════════════════════════════════%b\n\n' "$GREEN" "$NC"

    local _php
    _php="$(server_get DEFAULT_PHP 2>/dev/null)"
    _php="${_php:-8.5}"
    printf '%b  Stack:%b Nginx + PHP %s + MariaDB + Redis\n' "$BOLD" "$NC" "$_php"
    printf '%b  Next: %b mwp site create <domain>\n' "$BOLD" "$NC"
    printf '%b  Help: %b mwp help\n\n' "$BOLD" "$NC"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    print_banner
    preflight_checks

    # Collect optional inputs BEFORE automated steps (no interruptions mid-install)
    if [[ "${MWP_NONINTERACTIVE:-0}" == "1" ]]; then
        log_info "MWP_NONINTERACTIVE=1 — skipping panel URL prompt + start confirm."
        # Optional: caller can still preset panel via env
        if [[ -n "${MWP_PANEL_DOMAIN:-}" ]]; then
            if validate_domain "$MWP_PANEL_DOMAIN"; then
                server_set "PANEL_DOMAIN" "$MWP_PANEL_DOMAIN"
                log_sub "Panel hostname (from env): $MWP_PANEL_DOMAIN"
            else
                log_warn "MWP_PANEL_DOMAIN invalid — ignored."
            fi
        fi
    else
        step_panel_url_collect
        confirm "Start server setup?" || exit 0
    fi

    local start_time
    start_time="$(date +%s)"

    run_step 1  11 "System preparation"     step_system_prep
    run_step 2  11 "Installing Nginx"       step_nginx
    run_step 3  11 "Installing PHP 8.5"     step_php
    run_step 4  11 "Installing MariaDB"     step_mariadb
    run_step 5  11 "Installing Redis"       step_redis
    run_step 6  11 "Installing WP-CLI"      step_wpcli
    run_step 7  11 "Installing Certbot"     step_certbot
    run_step 8  11 "Firewall + Fail2ban"    step_firewall
    run_step 9  11 "Auto security updates"  step_auto_security_updates
    run_step 10 11 "Isolation hardening"    step_isolation
    run_step 11 11 "Panel URL setup"        step_panel_url_apply
    step_cli

    print_summary "$start_time"
}

# Only run main when executed directly, not when sourced
# (mwp panel setup sources this file to reuse step_panel_url_apply)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
