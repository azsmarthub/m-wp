#!/usr/bin/env bash
# lib/registry.sh — Site registry operations for mwp
# Manages /etc/mwp/sites/<slug>.conf

[[ -n "${_MWP_REGISTRY_LOADED:-}" ]] && return 0
_MWP_REGISTRY_LOADED=1

# ---------------------------------------------------------------------------
# Register a new site
# Called after site creation is complete
# ---------------------------------------------------------------------------
registry_add() {
    local domain="$1"
    local conf
    conf="$(site_conf_path "$domain")"

    [[ -f "$conf" ]] && die "Site '$domain' already registered."

    # All variables must be set in caller's scope before calling this
    cat > "$conf" <<EOF
DOMAIN=${domain}
SLUG=$(domain_to_slug "$domain")
SITE_USER=${SITE_USER}
PHP_VERSION=${PHP_VERSION}
WEB_ROOT=${WEB_ROOT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
REDIS_DB=${REDIS_DB}
CACHE_PATH=${CACHE_PATH}
STATUS=active
CREATED_AT=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    chmod 600 "$conf"
    log_success "Site '$domain' registered."
}

# ---------------------------------------------------------------------------
# Remove site from registry
# ---------------------------------------------------------------------------
registry_remove() {
    local domain="$1"
    local conf
    conf="$(site_conf_path "$domain")"

    [[ -f "$conf" ]] || die "Site '$domain' not in registry."
    rm -f "$conf"
    log_info "Site '$domain' removed from registry."
}

# ---------------------------------------------------------------------------
# Update site status
# ---------------------------------------------------------------------------
registry_set_status() {
    local domain="$1" status="$2"
    site_set "$domain" "STATUS" "$status"
}

# ---------------------------------------------------------------------------
# Pretty-print site list
# ---------------------------------------------------------------------------
registry_print_list() {
    local count=0
    local conf domain status php

    printf '\n%b%-30s %-10s %-8s %s%b\n' "$BOLD" "DOMAIN" "STATUS" "PHP" "WEB_ROOT" "$NC"
    printf '%s\n' "────────────────────────────────────────────────────────────────"

    for conf in "$MWP_SITES_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        domain="$(grep "^DOMAIN=" "$conf" | cut -d= -f2-)"
        status="$(grep "^STATUS=" "$conf" | cut -d= -f2-)"
        php="$(grep "^PHP_VERSION=" "$conf" | cut -d= -f2-)"
        web_root="$(grep "^WEB_ROOT=" "$conf" | cut -d= -f2-)"

        local color="$GREEN"
        [[ "$status" == "disabled" ]] && color="$YELLOW"

        printf '%b%-30s%b %-10s %-8s %s\n' "$color" "$domain" "$NC" "$status" "$php" "$web_root"
        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        printf '%bNo sites yet. Run: mwp site create <domain>%b\n' "$DIM" "$NC"
    else
        printf '\n%b%d site(s) total%b\n' "$DIM" "$count" "$NC"
    fi
    printf '\n'
}

# ---------------------------------------------------------------------------
# Pretty-print single site info
# ---------------------------------------------------------------------------
registry_print_info() {
    local domain="$1"
    site_exists "$domain" || die "Site '$domain' not found."

    local conf
    conf="$(site_conf_path "$domain")"

    printf '\n%b  Site: %s%b\n' "$BOLD" "$domain" "$NC"
    printf '  %s\n' "──────────────────────────────────────────"
    while IFS='=' read -r key val; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        # Hide password fields
        [[ "$key" == *PASS* || "$key" == *PASS ]] && val="***"
        printf '  %-18s %s\n' "$key" "$val"
    done < "$conf"
    printf '\n'
}
