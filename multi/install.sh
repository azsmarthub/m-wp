#!/usr/bin/env bash
# multi/install.sh — mwp server setup (run once on fresh VPS)
# Sets up: Nginx, PHP, MariaDB, Redis, WP-CLI, UFW, Fail2ban
# Usage: bash install.sh

if [[ ! -t 0 ]]; then
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

    # OS check
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        case "${ID:-}" in
            ubuntu)
                case "${VERSION_ID:-}" in
                    22.04|24.04) ;;
                    *) log_warn "Untested Ubuntu version: $VERSION_ID (recommended: 22.04 / 24.04)" ;;
                esac
                ;;
            debian) ;;
            *) log_warn "Untested OS: ${PRETTY_NAME:-unknown}" ;;
        esac
    fi

    # RAM
    local ram_mb
    ram_mb="$(detect_ram_mb)"
    if [[ $ram_mb -lt 1024 ]]; then
        log_warn "RAM: ${ram_mb}MB — minimum 1GB recommended (2GB+ for multi-site)"
        ok=0
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

    [[ $ok -eq 1 ]] || die "Pre-flight checks failed. Fix issues above and retry."
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

    cat > /etc/nginx/nginx.conf <<NGINXCONF
user www-data;
worker_processes auto;
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

step_php() {
    local default_php="8.3"

    if ! command -v php >/dev/null 2>&1; then
        log_sub "Adding PHP PPA (ondrej/php)..."
        apt_install software-properties-common
        add-apt-repository -y ppa:ondrej/php 2>&1 | tail -2 || true
        apt-get update -qq 2>&1 | tail -1 || true
    fi

    log_sub "Installing PHP ${default_php} + extensions..."
    apt_install \
        "php${default_php}-fpm" \
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
        log_sub "Installing MariaDB 10.11..."
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
    if command -v ufw >/dev/null 2>&1; then
        ufw --force reset >/dev/null 2>&1 || true
        ufw default deny incoming >/dev/null 2>&1
        ufw default allow outgoing >/dev/null 2>&1
        ufw allow ssh >/dev/null 2>&1
        ufw allow 'Nginx Full' >/dev/null 2>&1
        ufw --force enable >/dev/null 2>&1
        log_sub "UFW enabled (SSH + HTTP/HTTPS)"
    else
        apt_install ufw
        step_firewall
    fi
}

step_fail2ban() {
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

    printf '%b  Stack:%b Nginx + PHP 8.3 + MariaDB + Redis\n' "$BOLD" "$NC"
    printf '%b  Next: %b mwp site create <domain>\n' "$BOLD" "$NC"
    printf '%b  Help: %b mwp help\n\n' "$BOLD" "$NC"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    print_banner
    preflight_checks
    detect_ram_mb >/dev/null

    confirm "Start server setup?" || exit 0

    local start_time
    start_time="$(date +%s)"

    run_step 1 8 "System preparation"   step_system_prep
    run_step 2 8 "Installing Nginx"     step_nginx
    run_step 3 8 "Installing PHP 8.3"   step_php
    run_step 4 8 "Installing MariaDB"   step_mariadb
    run_step 5 8 "Installing Redis"     step_redis
    run_step 6 8 "Installing WP-CLI"    step_wpcli
    run_step 7 8 "Installing Certbot"   step_certbot
    run_step 8 8 "Firewall + Fail2ban"  step_firewall
    step_fail2ban
    step_cli

    print_summary "$start_time"
}

main "$@"
