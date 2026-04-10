#!/usr/bin/env bash
# lib/common.sh — Core library for mwp
# Colors, logging, state/registry management, helpers

[[ -n "${_MWP_COMMON_LOADED:-}" ]] && return 0
_MWP_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
MWP_STATE_DIR="/etc/mwp"
MWP_SITES_DIR="$MWP_STATE_DIR/sites"
MWP_SERVER_CONF="$MWP_STATE_DIR/server.conf"
MWP_LOG_DIR="/var/log/mwp"
MWP_LOG_FILE="$MWP_LOG_DIR/mwp.log"

# ---------------------------------------------------------------------------
# Init
# ---------------------------------------------------------------------------
mwp_init() {
    [[ ! -d "$MWP_STATE_DIR" ]] && mkdir -p "$MWP_STATE_DIR"
    [[ ! -d "$MWP_SITES_DIR" ]] && mkdir -p "$MWP_SITES_DIR"
    [[ ! -d "$MWP_LOG_DIR" ]]   && mkdir -p "$MWP_LOG_DIR"

    if [[ -z "${MWP_VERSION:-}" && -n "${MWP_DIR:-}" && -f "$MWP_DIR/VERSION" ]]; then
        MWP_VERSION="$(tr -d '[:space:]' < "$MWP_DIR/VERSION")"
    fi
    MWP_VERSION="${MWP_VERSION:-0.0.0}"
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log_to_file() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$MWP_LOG_FILE" 2>/dev/null || true
}

log_info() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1"
    _log_to_file "[INFO] $1"
}

log_success() {
    printf '[%s] %b✔%b  %s\n' "$(date '+%H:%M:%S')" "$GREEN" "$NC" "$1"
    _log_to_file "[OK]   $1"
}

log_warn() {
    printf '[%s] %b!%b  %s\n' "$(date '+%H:%M:%S')" "$YELLOW" "$NC" "$1" >&2
    _log_to_file "[WARN] $1"
}

log_error() {
    printf '[%s] %b✗%b  %s\n' "$(date '+%H:%M:%S')" "$RED" "$NC" "$1" >&2
    _log_to_file "[ERR]  $1"
}

log_sub() {
    printf '       %b→%b  %s\n' "$DIM" "$NC" "$1"
    _log_to_file "       $1"
}

log_step() {
    local num="$1" total="$2" desc="$3" status="${4:-OK}" elapsed="${5:-}"
    local color="$GREEN"
    [[ "$status" == "SKIP" ]] && color="$DIM"
    [[ "$status" == "ERR" ]]  && color="$RED"
    local elapsed_str=""
    [[ -n "$elapsed" ]] && elapsed_str=" (${elapsed}s)"
    printf '\n%b[%s/%s]%b %s ... %b%s%b%s\n' \
        "$BOLD" "$num" "$total" "$NC" "$desc" "$color" "$status" "$NC" "$elapsed_str"
    _log_to_file "[STEP $num/$total] $desc — $status$elapsed_str"
}

# ---------------------------------------------------------------------------
# Error trap
# ---------------------------------------------------------------------------
trap_error() {
    local line="$1" cmd="$2"
    log_error "Failed at line $line: $cmd"
    exit 1
}

die() {
    log_error "$1"
    exit 1
}

# ---------------------------------------------------------------------------
# User helpers
# ---------------------------------------------------------------------------
require_root() {
    [[ $EUID -eq 0 ]] || die "This command must be run as root."
}

confirm() {
    local prompt="${1:-Continue?} [y/N] "
    local reply
    printf '%b%s%b' "$BOLD" "$prompt" "$NC"
    read -r reply
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

# ---------------------------------------------------------------------------
# Password generator
# ---------------------------------------------------------------------------
generate_password() {
    local length="${1:-24}"
    tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom 2>/dev/null | head -c "$length" || \
        openssl rand -base64 "$length" | tr -dc 'A-Za-z0-9' | head -c "$length"
}

# ---------------------------------------------------------------------------
# Domain helpers
# ---------------------------------------------------------------------------
validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && return 0
    return 1
}

domain_to_slug() {
    # example.com → example_com (safe Linux username / filename)
    printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-32
}

# ---------------------------------------------------------------------------
# Server config (key=value in /etc/mwp/server.conf)
# ---------------------------------------------------------------------------
server_set() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$MWP_SERVER_CONF" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$MWP_SERVER_CONF"
    else
        printf '%s=%s\n' "$key" "$val" >> "$MWP_SERVER_CONF"
    fi
}

server_get() {
    local key="$1"
    grep "^${key}=" "$MWP_SERVER_CONF" 2>/dev/null | cut -d= -f2-
}

# ---------------------------------------------------------------------------
# Site registry
# Site config files: /etc/mwp/sites/<slug>.conf
# ---------------------------------------------------------------------------
site_conf_path() {
    local slug
    slug="$(domain_to_slug "$1")"
    printf '%s/%s.conf' "$MWP_SITES_DIR" "$slug"
}

site_set() {
    local domain="$1" key="$2" val="$3"
    local conf
    conf="$(site_conf_path "$domain")"
    if grep -q "^${key}=" "$conf" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$conf"
    else
        printf '%s=%s\n' "$key" "$val" >> "$conf"
    fi
}

site_get() {
    local domain="$1" key="$2"
    local conf
    conf="$(site_conf_path "$domain")"
    grep "^${key}=" "$conf" 2>/dev/null | cut -d= -f2-
}

site_exists() {
    local conf
    conf="$(site_conf_path "$1")"
    [[ -f "$conf" ]]
}

site_list() {
    local conf slug
    for conf in "$MWP_SITES_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        slug="$(basename "$conf" .conf)"
        grep "^DOMAIN=" "$conf" 2>/dev/null | cut -d= -f2- || printf '%s\n' "$slug"
    done
}

site_count() {
    local count=0
    local conf
    for conf in "$MWP_SITES_DIR"/*.conf; do
        [[ -f "$conf" ]] && count=$((count + 1))
    done
    printf '%d' "$count"
}

load_site_config() {
    local domain="$1"
    site_exists "$domain" || die "Site '$domain' not found in registry."
    local conf
    conf="$(site_conf_path "$domain")"
    # shellcheck source=/dev/null
    source "$conf"
}

# ---------------------------------------------------------------------------
# Redis DB index allocation (0–15 per site)
# ---------------------------------------------------------------------------
redis_alloc_db() {
    local domain="$1"
    local used=()
    local conf

    # Collect all used DB indexes
    for conf in "$MWP_SITES_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        local idx
        idx="$(grep "^REDIS_DB=" "$conf" 2>/dev/null | cut -d= -f2-)"
        [[ -n "$idx" ]] && used+=("$idx")
    done

    # Find first available index 0–15
    local i
    for i in $(seq 0 15); do
        local taken=0
        local u
        for u in "${used[@]:-}"; do
            [[ "$u" == "$i" ]] && taken=1 && break
        done
        [[ $taken -eq 0 ]] && printf '%d' "$i" && return 0
    done

    die "No available Redis DB index (max 16 sites using shared Redis). Consider dedicated Redis per site."
}

# ---------------------------------------------------------------------------
# Package helpers
# ---------------------------------------------------------------------------
apt_wait() {
    local i=0
    while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock \
          /var/lib/dpkg/lock >/dev/null 2>&1; do
        [[ $i -eq 0 ]] && log_sub "Waiting for package manager lock..."
        sleep 2
        i=$((i + 1))
        [[ $i -gt 30 ]] && die "Package manager lock timeout."
    done
}

apt_install() {
    apt_wait
    local log_file="/tmp/mwp-apt-$$.log"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@" >"$log_file" 2>&1
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "apt-get install failed (rc=$rc) for: $*"
        log_error "Last 20 lines of apt log ($log_file):"
        tail -20 "$log_file" >&2 || true
        die "apt install aborted — see $log_file for full output"
    fi
    grep -E "^(Setting up|Unpacking)" "$log_file" | tail -5 || true
    rm -f "$log_file"
}

# ---------------------------------------------------------------------------
# Service helpers
# ---------------------------------------------------------------------------
service_restart() {
    systemctl restart "$1" || die "Failed to restart $1"
}

service_reload() {
    systemctl reload "$1" || die "Failed to reload $1"
}

service_enable() {
    systemctl enable "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Template renderer
# Replaces {{VAR}} in template with env var $VAR
# ---------------------------------------------------------------------------
render_template() {
    local tpl="$1"
    [[ -f "$tpl" ]] || die "Template not found: $tpl"

    local output
    output="$(cat "$tpl")"

    # Replace all {{KEY}} with value of $KEY from environment
    while IFS= read -r line; do
        while [[ "$line" =~ \{\{([A-Z0-9_]+)\}\} ]]; do
            local var="${BASH_REMATCH[1]}"
            local val="${!var:-}"
            line="${line/\{\{${var}\}\}/$val}"
        done
        printf '%s\n' "$line"
    done <<< "$output"
}

# ---------------------------------------------------------------------------
# Hardware detection (lightweight, no external deps)
# ---------------------------------------------------------------------------
detect_ram_mb() {
    awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo
}

detect_cpu_cores() {
    nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo
}

detect_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || \
        ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}' || \
        echo "unknown"
}
