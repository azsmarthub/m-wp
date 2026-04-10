#!/usr/bin/env bash
# lib/multi-isolation.sh — Isolation hardening for mwp
# Applied at install time (global) + per site at creation time

[[ -n "${_MWP_ISOLATION_LOADED:-}" ]] && return 0
_MWP_ISOLATION_LOADED=1

# ---------------------------------------------------------------------------
# Global isolation — called once in install.sh
# Sets /home to 711: users can traverse but cannot list each other's dirs
# ---------------------------------------------------------------------------
isolation_global_apply() {
    chmod 711 /home
    log_sub "/home permissions set to 711 (traverse-only)"

    # Harden /etc/mwp (state dir)
    chmod 700 "$MWP_STATE_DIR"
    chmod 700 "$MWP_SITES_DIR"
    chmod 600 "$MWP_SERVER_CONF" 2>/dev/null || true
    log_sub "/etc/mwp permissions hardened (root-only)"
}

# ---------------------------------------------------------------------------
# Per-site isolation — called in site_create() after user is created
# ---------------------------------------------------------------------------
isolation_site_apply() {
    local site_user="$1" web_root="$2"

    # Home dir: owner rwx, group/other none
    chmod 750 "/home/${site_user}"
    # www-data needs +x to traverse into web root for static files
    # (www-data is added to site group in site_create)

    # WordPress dirs: 750, files: 640
    find "$web_root" -type d -exec chmod 750 {} \; 2>/dev/null || true
    find "$web_root" -type f -exec chmod 640 {} \; 2>/dev/null || true

    # wp-config.php: owner read-only
    [[ -f "${web_root}/wp-config.php" ]] && chmod 600 "${web_root}/wp-config.php"

    # Writable dirs WordPress needs (uploads, cache)
    chmod 770 "${web_root}/wp-content" 2>/dev/null || true
    chmod 770 "${web_root}/wp-content/uploads" 2>/dev/null || true
    mkdir -p "${web_root}/wp-content/cache" && chmod 770 "${web_root}/wp-content/cache" 2>/dev/null || true

    # tmp dir for PHP uploads/sessions (writable by site user only)
    chmod 700 "/home/${site_user}/tmp" 2>/dev/null || true

    log_sub "Filesystem isolation applied for ${site_user}"
}

# ---------------------------------------------------------------------------
# check-isolation <domain> — diagnostic report
# ---------------------------------------------------------------------------
isolation_check() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && die "Usage: mwp site check-isolation <domain>"
    site_exists "$domain" || die "Site '$domain' not found."

    local site_user web_root php_version db_name db_user redis_db
    site_user="$(site_get "$domain" SITE_USER)"
    web_root="$(site_get "$domain" WEB_ROOT)"
    php_version="$(site_get "$domain" PHP_VERSION)"
    db_name="$(site_get "$domain" DB_NAME)"
    db_user="$(site_get "$domain" DB_USER)"
    redis_db="$(site_get "$domain" REDIS_DB)"

    printf '\n%b  Isolation Check: %s%b\n' "$BOLD" "$domain" "$NC"
    printf '  %s\n' "──────────────────────────────────────────────"

    local pass=0 fail=0

    _iso_check() {
        local label="$1" result="$2" expected="$3"
        if [[ "$result" == "$expected" ]]; then
            printf '  %b✔%b  %-35s %s\n' "$GREEN" "$NC" "$label" "$result"
            pass=$(( pass + 1 ))
        else
            printf '  %b✗%b  %-35s got: %s (expected: %s)\n' "$RED" "$NC" "$label" "$result" "$expected"
            fail=$(( fail + 1 ))
        fi
    }

    _iso_warn() {
        local label="$1" msg="$2"
        printf '  %b!%b  %-35s %s\n' "$YELLOW" "$NC" "$label" "$msg"
    }

    # /home permissions
    local home_perm
    home_perm="$(stat -c '%a' /home 2>/dev/null)"
    _iso_check "/home permissions" "$home_perm" "711"

    # Site home dir permissions
    local site_home_perm
    site_home_perm="$(stat -c '%a' "/home/${site_user}" 2>/dev/null || echo 'missing')"
    _iso_check "/home/${site_user} permissions" "$site_home_perm" "750"

    # Site user shell (should be nologin)
    local user_shell
    user_shell="$(getent passwd "$site_user" 2>/dev/null | cut -d: -f7 || echo 'user not found')"
    _iso_check "Site user shell" "$user_shell" "/usr/sbin/nologin"

    # PHP-FPM pool file exists
    local pool_file="/etc/php/${php_version}/fpm/pool.d/${site_user}.conf"
    if [[ -f "$pool_file" ]]; then
        printf '  %b✔%b  %-35s %s\n' "$GREEN" "$NC" "PHP-FPM pool file" "$pool_file"
        pass=$(( pass + 1 ))

        # open_basedir set in pool
        if grep -q "open_basedir" "$pool_file" 2>/dev/null; then
            printf '  %b✔%b  %-35s set\n' "$GREEN" "$NC" "PHP open_basedir"
            pass=$(( pass + 1 ))
        else
            printf '  %b✗%b  %-35s NOT SET\n' "$RED" "$NC" "PHP open_basedir"
            fail=$(( fail + 1 ))
        fi

        # disable_functions set in pool
        if grep -q "disable_functions" "$pool_file" 2>/dev/null; then
            printf '  %b✔%b  %-35s set\n' "$GREEN" "$NC" "PHP disable_functions"
            pass=$(( pass + 1 ))
        else
            printf '  %b✗%b  %-35s NOT SET\n' "$RED" "$NC" "PHP disable_functions"
            fail=$(( fail + 1 ))
        fi

        # Pool user matches site user
        local pool_user
        pool_user="$(grep "^user " "$pool_file" 2>/dev/null | awk '{print $3}')"
        _iso_check "PHP-FPM pool user" "$pool_user" "$site_user"
    else
        printf '  %b✗%b  %-35s NOT FOUND\n' "$RED" "$NC" "PHP-FPM pool file"
        fail=$(( fail + 1 ))
    fi

    # MariaDB: user only has access to own DB
    local root_pass
    root_pass="$(server_get "DB_ROOT_PASS")"
    if [[ -n "$root_pass" ]]; then
        local db_grants
        db_grants="$(mysql -u root -p"${root_pass}" -se \
            "SHOW GRANTS FOR '${db_user}'@'localhost';" 2>/dev/null || echo '')"
        if echo "$db_grants" | grep -q "${db_name}"; then
            # Flag global privileges, but ignore the harmless "GRANT USAGE ON *.*"
            # which MariaDB always emits for any user (it just means "can login").
            if echo "$db_grants" | grep -E "ON \*\.\*" | grep -qvE "GRANT USAGE ON"; then
                printf '  %b✗%b  %-35s has global privileges!\n' "$RED" "$NC" "MariaDB grants"
                fail=$(( fail + 1 ))
            else
                printf '  %b✔%b  %-35s only on %s\n' "$GREEN" "$NC" "MariaDB grants" "$db_name"
                pass=$(( pass + 1 ))
            fi
        else
            _iso_warn "MariaDB grants" "Could not verify (check manually)"
        fi
    else
        _iso_warn "MariaDB grants" "DB root pass not found in server.conf"
    fi

    # Redis DB isolation
    local all_redis_dbs=()
    local conf
    for conf in "$MWP_SITES_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        local idx
        idx="$(grep "^REDIS_DB=" "$conf" 2>/dev/null | cut -d= -f2-)"
        [[ -n "$idx" ]] && all_redis_dbs+=("$idx")
    done
    # Check uniqueness
    local unique_count total_count
    unique_count="$(printf '%s\n' "${all_redis_dbs[@]}" | sort -u | wc -l)"
    total_count="${#all_redis_dbs[@]}"
    if [[ "$unique_count" -eq "$total_count" ]]; then
        printf '  %b✔%b  %-35s DB index %s (unique)\n' "$GREEN" "$NC" "Redis isolation" "$redis_db"
        pass=$(( pass + 1 ))
    else
        printf '  %b✗%b  %-35s DB index %s CONFLICTS with another site!\n' "$RED" "$NC" "Redis isolation" "$redis_db"
        fail=$(( fail + 1 ))
    fi

    # Nginx vhost exists and isolated socket
    local vhost="/etc/nginx/sites-available/${domain}.conf"
    if [[ -f "$vhost" ]]; then
        if grep -q "${site_user}.sock" "$vhost"; then
            printf '  %b✔%b  %-35s uses isolated PHP socket\n' "$GREEN" "$NC" "Nginx PHP socket"
            pass=$(( pass + 1 ))
        else
            printf '  %b✗%b  %-35s socket not isolated\n' "$RED" "$NC" "Nginx PHP socket"
            fail=$(( fail + 1 ))
        fi
    else
        printf '  %b✗%b  %-35s vhost not found\n' "$RED" "$NC" "Nginx vhost"
        fail=$(( fail + 1 ))
    fi

    # Summary
    printf '  %s\n' "──────────────────────────────────────────────"
    local total=$(( pass + fail ))
    if [[ $fail -eq 0 ]]; then
        printf '  %b✔ All %d checks passed%b\n\n' "$GREEN" "$total" "$NC"
    else
        printf '  %b%d/%d checks passed — %d issues found%b\n\n' \
            "$YELLOW" "$pass" "$total" "$fail" "$NC"
    fi
}
