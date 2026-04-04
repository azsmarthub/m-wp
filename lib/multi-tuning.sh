#!/usr/bin/env bash
# lib/multi-tuning.sh — Auto-tune PHP-FPM pools for all sites
# Recalculates pm.max_children + memory_limit based on current RAM / site count
# Called automatically after site create/delete, or manually via: mwp retune

[[ -n "${_MWP_TUNING_LOADED:-}" ]] && return 0
_MWP_TUNING_LOADED=1

# ---------------------------------------------------------------------------
# Recalculate + rewrite ALL active site FPM pools
# Safe to call any time — idempotent
# ---------------------------------------------------------------------------
tuning_retune_all() {
    local site_count
    site_count="$(site_count)"

    if [[ $site_count -eq 0 ]]; then
        log_sub "No sites to retune."
        return 0
    fi

    local ram_mb
    ram_mb="$(detect_ram_mb)"

    local new_children new_memory
    new_children="$(tuning_calc_children "$ram_mb" "$site_count")"
    new_memory="$(tuning_calc_memory "$ram_mb" "$site_count")"

    log_sub "Retuning ${site_count} site(s): RAM=${ram_mb}MB → pm.max_children=${new_children}, memory_limit=${new_memory}M"

    local conf updated=0
    for conf in "$MWP_SITES_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue

        local domain site_user php_version status
        domain="$(grep "^DOMAIN=" "$conf" | cut -d= -f2-)"
        site_user="$(grep "^SITE_USER=" "$conf" | cut -d= -f2-)"
        php_version="$(grep "^PHP_VERSION=" "$conf" | cut -d= -f2-)"
        status="$(grep "^STATUS=" "$conf" | cut -d= -f2-)"

        # Skip disabled sites
        [[ "$status" == "disabled" ]] && continue

        local pool_file="/etc/php/${php_version}/fpm/pool.d/${site_user}.conf"
        [[ -f "$pool_file" ]] || continue

        # Update pm.max_children
        sed -i "s|^pm\.max_children\s*=.*|pm.max_children = ${new_children}|" "$pool_file"

        # Update memory_limit
        sed -i "s|^php_admin_value\[memory_limit\]\s*=.*|php_admin_value[memory_limit] = ${new_memory}M|" "$pool_file"

        updated=$(( updated + 1 ))
    done

    # Reload all active PHP-FPM versions
    local php_vers=()
    for conf in "$MWP_SITES_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        local ver
        ver="$(grep "^PHP_VERSION=" "$conf" | cut -d= -f2-)"
        [[ -n "$ver" ]] && php_vers+=("$ver")
    done

    # Reload unique versions
    local reloaded=()
    local v
    for v in "${php_vers[@]:-}"; do
        local already=0
        local r
        for r in "${reloaded[@]:-}"; do [[ "$r" == "$v" ]] && already=1; done
        if [[ $already -eq 0 ]]; then
            systemctl reload "php${v}-fpm" 2>/dev/null || \
                systemctl restart "php${v}-fpm" 2>/dev/null || true
            reloaded+=("$v")
        fi
    done

    log_success "Retuned ${updated} pool(s) — pm.max_children=${new_children}, memory_limit=${new_memory}M"
}

# ---------------------------------------------------------------------------
# Print retune report without applying (dry-run)
# ---------------------------------------------------------------------------
tuning_report() {
    local site_count
    site_count="$(site_count)"
    local ram_mb
    ram_mb="$(detect_ram_mb)"

    local new_children new_memory
    new_children="$(tuning_calc_children "$ram_mb" "$site_count")"
    new_memory="$(tuning_calc_memory "$ram_mb" "$site_count")"

    printf '\n%b  mwp Tuning Report%b\n' "$BOLD" "$NC"
    printf '  %s\n' "──────────────────────────────────────────"
    printf '  Server RAM:       %sMB\n' "$ram_mb"
    printf '  Active sites:     %s\n' "$site_count"
    printf '  pm.max_children:  %s per site\n' "$new_children"
    printf '  memory_limit:     %sMB per site\n' "$new_memory"
    printf '  Max total PHP:    %sMB (worst case)\n' "$(( new_children * new_memory * site_count ))"
    printf '\n'

    if [[ $site_count -gt 0 ]]; then
        printf '%b  Current pool config:%b\n' "$BOLD" "$NC"
        local conf
        for conf in "$MWP_SITES_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            local domain site_user php_version
            domain="$(grep "^DOMAIN=" "$conf" | cut -d= -f2-)"
            site_user="$(grep "^SITE_USER=" "$conf" | cut -d= -f2-)"
            php_version="$(grep "^PHP_VERSION=" "$conf" | cut -d= -f2-)"
            local pool_file="/etc/php/${php_version}/fpm/pool.d/${site_user}.conf"
            local current_children="(pool missing)"
            if [[ -f "$pool_file" ]]; then
                current_children="$(grep "^pm\.max_children" "$pool_file" | awk '{print $3}')"
            fi
            printf '  %-30s PHP %s  pm.max_children=%s\n' \
                "$domain" "$php_version" "$current_children"
        done
        printf '\n'
    fi
}

# ---------------------------------------------------------------------------
# Calculation helpers (same formula as multi-php.sh, single source of truth)
# ---------------------------------------------------------------------------
tuning_calc_children() {
    local ram_mb="$1" site_count="$2"
    [[ $site_count -eq 0 ]] && site_count=1
    local available=$(( ram_mb - 384 ))   # reserve 384MB for OS + services
    [[ $available -lt 128 ]] && available=128
    local per_site=$(( available / site_count ))
    local children=$(( per_site / 32 ))   # ~32MB per PHP worker
    [[ $children -lt 2 ]]  && children=2
    [[ $children -gt 12 ]] && children=12
    printf '%d' "$children"
}

tuning_calc_memory() {
    local ram_mb="$1" site_count="$2"
    [[ $site_count -eq 0 ]] && site_count=1
    local limit=$(( (ram_mb - 384) / site_count ))
    [[ $limit -lt 64 ]]  && limit=64
    [[ $limit -gt 512 ]] && limit=512
    printf '%d' "$limit"
}
