#!/usr/bin/env bash
# lib/multi-menu.sh — Interactive TUI menus for mwp
#
# 3-level hierarchy:
#   menu_root          Level 0: server management hub
#   menu_sites         Level 1: site list (with optional filter)
#   menu_site_detail   Level 2: per-site actions
#   menu_php / menu_ssl_list / menu_backup / menu_server / menu_settings   Level 1 categories

[[ -n "${_MWP_MENU_LOADED:-}" ]] && return 0
_MWP_MENU_LOADED=1

# Global: populated by _sites_table() for numeric site selection
MENU_SITES=()
MENU_INPUT=""

# ──────────────────────────────────────────────────────────────────────
# UI primitives
# ──────────────────────────────────────────────────────────────────────

_mc()   { printf '\033[2J\033[H'; }
_mhr()  { printf '  ─────────────────────────────────────────────────────────\n'; }
_mhr2() { printf '  ═════════════════════════════════════════════════════════\n'; }

_mpause() {
    printf '\n  Press ENTER to continue...'
    read -r _mwp_p || true
}

_mprompt() {
    printf '\n  %b%s:%b ' "$BOLD" "${1:-Select}" "$NC"
    read -r MENU_INPUT || MENU_INPUT="0"
    MENU_INPUT="${MENU_INPUT,,}"
}

# ──────────────────────────────────────────────────────────────────────
# Screen header (common to all levels)
# ──────────────────────────────────────────────────────────────────────

_mheader() {
    local subtitle="${1:-}"
    local _ip _ram _cpu _cnt _def_php _svc _lbl
    _ip="$(server_get SERVER_IP 2>/dev/null || detect_ip)"
    _ram="$(detect_ram_mb)"
    _cpu="$(detect_cpu_cores)"
    _cnt="$(site_count)"
    _def_php="$(server_get DEFAULT_PHP 2>/dev/null || printf '8.3')"

    _mc
    _mhr2
    if [[ -n "$subtitle" ]]; then
        printf '  %bmwp%b  ──  %b%s%b\n' "$BOLD" "$NC" "$BOLD" "$subtitle" "$NC"
    else
        printf '  %bmwp%b v%s\n' "$BOLD" "$NC" "$MWP_VERSION"
    fi
    printf '  %s  │  RAM: %sMB  │  CPU: %s  │  Sites: %s\n' \
        "$_ip" "$_ram" "$_cpu" "$_cnt"
    printf '  '
    for _svc in nginx mariadb redis-server "php${_def_php}-fpm"; do
        _lbl="$_svc"
        [[ "$_svc" == "redis-server" ]] && _lbl="redis"
        if systemctl is-active --quiet "$_svc" 2>/dev/null; then
            printf '%b%s ✔%b  ' "$GREEN" "$_lbl" "$NC"
        else
            printf '%b%s ✗%b  ' "$RED"   "$_lbl" "$NC"
        fi
    done
    printf '\n'
    _mhr2
}

# ──────────────────────────────────────────────────────────────────────
# Sites table  (populates global MENU_SITES[])
# ──────────────────────────────────────────────────────────────────────

_ssl_icon() {
    local _dom="$1"
    local _cert="/etc/letsencrypt/live/${_dom}/fullchain.pem"
    [[ ! -f "$_cert" ]] && printf '✗' && return
    local _exp _now
    _exp="$(openssl x509 -enddate -noout -in "$_cert" 2>/dev/null \
            | cut -d= -f2 | xargs -I{} date -d '{}' +%s 2>/dev/null)" || _exp=0
    _now="$(date +%s)"
    [[ ${_exp:-0} -gt $_now ]] && printf '✔' || printf '!'
}

_disk_usage() {
    local _u="$1"
    [[ -d "/home/${_u}" ]] \
        && du -sh "/home/${_u}" 2>/dev/null | cut -f1 \
        || printf '-'
}

_sites_table() {
    local filter="${1:-}"
    local _conf _d _st _php _su _ssl _disk _st_col _idx
    MENU_SITES=()
    _idx=0

    printf '\n'
    printf '  %b%-3s  %-30s  %-10s  %-5s  %-3s  %-8s%b\n' \
        "$BOLD" "#" "DOMAIN" "STATUS" "PHP" "SSL" "DISK" "$NC"
    _mhr

    if ! ls "$MWP_SITES_DIR"/*.conf &>/dev/null 2>&1; then
        printf '  (no sites yet — press [c] to create one)\n'
        _mhr; return 0
    fi

    for _conf in "$MWP_SITES_DIR"/*.conf; do
        [[ -f "$_conf" ]] || continue
        _d="$(grep  "^DOMAIN="       "$_conf" | cut -d= -f2-)"
        _st="$(grep "^STATUS="       "$_conf" | cut -d= -f2-)"
        _php="$(grep "^PHP_VERSION=" "$_conf" | cut -d= -f2-)"
        _su="$(grep  "^SITE_USER="   "$_conf" | cut -d= -f2-)"

        [[ -n "$filter" && "$_d" != *"$filter"* ]] && continue

        _idx=$(( _idx + 1 ))
        MENU_SITES+=("$_d")

        _ssl="$(_ssl_icon "$_d")"
        _disk="$(_disk_usage "$_su")"

        # Manually pad status to same visible width (color codes are non-printing)
        case "$_st" in
            active)   _st_col="$(printf '%bactive    %b' "$GREEN" "$NC")" ;;
            disabled) _st_col="$(printf '%bdisabled  %b' "$RED"   "$NC")" ;;
            *)        _st_col="$(printf '%b%-10s%b'      "$BOLD"  "$_st" "$NC")" ;;
        esac

        printf '  %b%-3s%b  %-30s  %s  %-5s  %-3s  %s\n' \
            "$BOLD" "$_idx" "$NC" "$_d" "$_st_col" "$_php" "$_ssl" "$_disk"
    done

    _mhr
    [[ $_idx -eq 0 && -n "$filter" ]] && \
        printf '  (no sites match: "%s")\n' "$filter" && _mhr
    return 0
}

# ──────────────────────────────────────────────────────────────────────
# Level 0 — Root menu
# ──────────────────────────────────────────────────────────────────────

menu_root() {
    _mheader
    printf '\n'
    printf '  %b[1]%b  Sites management\n'         "$BOLD" "$NC"
    printf '  %b[2]%b  PHP versions\n'             "$BOLD" "$NC"
    printf '  %b[3]%b  SSL certificates\n'         "$BOLD" "$NC"
    printf '  %b[4]%b  Backups & Restore\n'        "$BOLD" "$NC"
    printf '  %b[5]%b  Server status & tuning\n'   "$BOLD" "$NC"
    printf '  %b[6]%b  Settings\n'                 "$BOLD" "$NC"
    _mhr
    printf '  %b[0]%b  Exit\n' "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1) _load_site_libs; menu_sites ;;
        2) _load_site_libs; menu_php ;;
        3) _load_site_libs; menu_ssl_list ;;
        4) _load_site_libs; menu_backup ;;
        5) _load_site_libs; menu_server ;;
        6) menu_settings ;;
        0|q|exit) printf '\n'; exit 0 ;;
        *) menu_root ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Level 1 — Sites list
# ──────────────────────────────────────────────────────────────────────

menu_sites() {
    local filter="${1:-}"
    local _new_dom _kw

    _mheader "Sites"
    [[ -n "$filter" ]] && printf '  Filter: %b%s%b\n' "$BOLD" "$filter" "$NC"
    _sites_table "$filter"

    printf '  %b[c]%b New site' "$BOLD" "$NC"
    [[ -n "$filter" ]] && printf '    %b[x]%b Clear filter' "$BOLD" "$NC"
    printf '    %b[/]%b Filter    %b[0]%b Back\n' "$BOLD" "$NC" "$BOLD" "$NC"
    _mprompt "Site # or action"

    case "$MENU_INPUT" in
        0|b|back)
            menu_root; return
            ;;
        c|create)
            _mc
            printf '\n  %bCreate new site%b\n' "$BOLD" "$NC"
            _mhr
            printf '  Domain (e.g. example.com): '
            read -r _new_dom
            if [[ -n "$_new_dom" ]]; then
                require_root
                site_create "$_new_dom" || true
                _mpause
            fi
            menu_sites "$filter"
            ;;
        /|f|filter)
            printf '  Keyword: '
            read -r _kw
            menu_sites "$_kw"
            ;;
        x|clear)
            menu_sites
            ;;
        '')
            menu_sites "$filter"
            ;;
        *)
            if [[ "$MENU_INPUT" =~ ^[0-9]+$ ]] && \
               [[ $MENU_INPUT -ge 1 && $MENU_INPUT -le ${#MENU_SITES[@]} ]]; then
                menu_site_detail "${MENU_SITES[$((MENU_INPUT-1))]}"
                menu_sites "$filter"
            else
                menu_sites "$filter"
            fi
            ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Level 2 — Site detail
# ──────────────────────────────────────────────────────────────────────

menu_site_detail() {
    local domain="$1"
    site_exists "$domain" || { log_warn "Site '$domain' not found."; return; }

    local _st _php _su _webroot _db _rdb _ssl _disk _toggle _st_col

    _st="$(site_get "$domain" STATUS)"
    _php="$(site_get "$domain" PHP_VERSION)"
    _su="$(site_get "$domain" SITE_USER)"
    _webroot="$(site_get "$domain" WEB_ROOT)"
    _db="$(site_get "$domain" DB_NAME)"
    _rdb="$(site_get "$domain" REDIS_DB)"
    _ssl="$(_ssl_icon "$domain")"
    _disk="$(_disk_usage "$_su")"
    [[ "$_st" == "active" ]] && _toggle="Disable" || _toggle="Enable"
    [[ "$_st" == "active" ]] \
        && _st_col="$(printf '%b%s%b' "$GREEN" "$_st" "$NC")" \
        || _st_col="$(printf '%b%s%b' "$RED"   "$_st" "$NC")"

    _mheader "$domain"
    printf '\n'
    printf '  Status: %s  │  PHP: %s  │  SSL: %s  │  Disk: %s\n' \
        "$_st_col" "$_php" "$_ssl" "$_disk"
    printf '  User: %s  │  DB: %s  │  Redis DB: %s\n' "$_su" "$_db" "$_rdb"
    printf '  Root: %s\n' "$_webroot"
    _mhr
    printf '\n'
    printf '  %b[1]%b  Info & details          %b[6]%b  Restore from backup\n'  "$BOLD" "$NC" "$BOLD" "$NC"
    printf '  %b[2]%b  %-8s site          %b[7]%b  Check isolation\n'           "$BOLD" "$NC" "$_toggle" "$BOLD" "$NC"
    printf '  %b[3]%b  Switch PHP version      %b[8]%b  Enter site shell\n'     "$BOLD" "$NC" "$BOLD" "$NC"
    printf '  %b[4]%b  Purge cache             %b[9]%b  SSL manage\n'           "$BOLD" "$NC" "$BOLD" "$NC"
    printf '  %b[5]%b  Backup\n'                                                "$BOLD" "$NC"
    _mhr
    printf '  %b[d]%b  Delete site             %b[0]%b  Back\n' "$BOLD" "$NC" "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1)
            _mc; registry_print_info "$domain"; _mpause
            menu_site_detail "$domain"
            ;;
        2)
            require_root
            if [[ "$_st" == "active" ]]; then
                site_disable "$domain"
            else
                site_enable "$domain"
            fi
            _mpause; menu_site_detail "$domain"
            ;;
        3)
            _menu_php_switch "$domain"
            menu_site_detail "$domain"
            ;;
        4)
            _mc; printf '\n  Purging cache for %s...\n' "$domain"
            cache_purge_site "$domain"; _mpause
            menu_site_detail "$domain"
            ;;
        5)
            _menu_do_backup "$domain"
            menu_site_detail "$domain"
            ;;
        6)
            _menu_do_restore "$domain"
            menu_site_detail "$domain"
            ;;
        7)
            _mc; isolation_check "$domain"; _mpause
            menu_site_detail "$domain"
            ;;
        8)
            printf '\n  %bEntering shell for user: %s%b\n' "$BOLD" "$_su" "$NC"
            printf '  Type "exit" to return to mwp.\n\n'
            su -s /bin/bash - "$_su" || true
            menu_site_detail "$domain"
            ;;
        9)
            _menu_do_ssl "$domain"
            menu_site_detail "$domain"
            ;;
        d|delete)
            require_root
            site_delete "$domain" || true
            return   # back to site list
            ;;
        0|b|back) return ;;
        *) menu_site_detail "$domain" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Site detail action helpers
# ──────────────────────────────────────────────────────────────────────

_menu_php_switch() {
    local domain="$1"
    local _cur _new_ver
    _cur="$(site_get "$domain" PHP_VERSION)"

    _mc
    printf '\n  %bSwitch PHP — %s%b\n' "$BOLD" "$domain" "$NC"
    _mhr
    php_list_versions
    _mhr
    printf '  Current: PHP %s\n' "$_cur"
    printf '  New version (8.1 / 8.2 / 8.3 / 8.4 — or ENTER to cancel): '
    read -r _new_ver

    if [[ -n "$_new_ver" && "$_new_ver" != "$_cur" ]]; then
        require_root
        php_switch_site "$domain" "$_new_ver" || true
        _mpause
    elif [[ "$_new_ver" == "$_cur" ]]; then
        log_warn "Already using PHP $_cur"
        _mpause
    fi
}

_menu_do_backup() {
    local domain="$1"
    _mc
    printf '\n  %bBackup — %s%b\n' "$BOLD" "$domain" "$NC"
    _mhr
    printf '  %b[1]%b  Full backup (files + database)\n' "$BOLD" "$NC"
    printf '  %b[2]%b  Database only\n'                   "$BOLD" "$NC"
    printf '  %b[0]%b  Cancel\n'                          "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1) require_root; backup_site "$domain" "full"; _mpause ;;
        2) require_root; backup_site "$domain" "db";   _mpause ;;
        *) return ;;
    esac
}

_menu_do_restore() {
    local domain="$1"
    local _su _bdir _f _idx _size _sel
    local -a _files=()
    _su="$(site_get "$domain" SITE_USER)"
    _bdir="/home/${_su}/backups"

    _mc
    printf '\n  %bRestore — %s%b\n' "$BOLD" "$domain" "$NC"
    _mhr

    _idx=0
    for _f in "$_bdir"/*.tar.gz "$_bdir"/*.sql.gz; do
        [[ -f "$_f" ]] || continue
        _idx=$(( _idx + 1 ))
        _files+=("$_f")
        _size="$(du -sh "$_f" 2>/dev/null | cut -f1)"
        printf '  %b[%s]%b  %-45s  %s\n' \
            "$BOLD" "$_idx" "$NC" "$(basename "$_f")" "$_size"
    done

    if [[ $_idx -eq 0 ]]; then
        printf '  No backup files found in %s\n' "$_bdir"
        _mpause; return
    fi

    _mhr
    printf '  %b[0]%b  Cancel\n' "$BOLD" "$NC"
    _mprompt "Select file #"

    if [[ "$MENU_INPUT" =~ ^[0-9]+$ ]] && \
       [[ $MENU_INPUT -ge 1 && $MENU_INPUT -le ${#_files[@]} ]]; then
        _sel="${_files[$((MENU_INPUT-1))]}"
        printf '\n  Restoring: %s\n' "$(basename "$_sel")"
        require_root
        restore_site "$domain" "$_sel" || true
        _mpause
    fi
}

_menu_do_ssl() {
    local domain="$1"
    local _cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
    local _exp

    _mc
    printf '\n  %bSSL — %s%b\n' "$BOLD" "$domain" "$NC"
    _mhr
    if [[ -f "$_cert" ]]; then
        _exp="$(openssl x509 -enddate -noout -in "$_cert" 2>/dev/null | cut -d= -f2)"
        printf '  Certificate:  %b✔ Active%b\n' "$GREEN" "$NC"
        printf '  Expires:      %s\n' "$_exp"
    else
        printf '  Certificate:  %b✗ Not issued%b\n' "$RED" "$NC"
    fi
    _mhr
    printf '  %b[1]%b  Issue / re-issue SSL\n'   "$BOLD" "$NC"
    printf '  %b[2]%b  Check live SSL status\n'  "$BOLD" "$NC"
    printf '  %b[0]%b  Back\n'                   "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1)
            require_root; ssl_issue "$domain" || true; _mpause
            ;;
        2)
            echo | openssl s_client -connect "${domain}:443" -servername "$domain" 2>/dev/null \
                | openssl x509 -noout -dates 2>/dev/null \
                || log_warn "SSL connection failed or no certificate."
            _mpause
            ;;
        *) return ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Level 1 — PHP versions
# ──────────────────────────────────────────────────────────────────────

menu_php() {
    local _ver _sel
    _mheader "PHP Versions"
    printf '\n'
    php_list_versions
    _mhr
    printf '  %b[i]%b  Install new PHP version\n'   "$BOLD" "$NC"
    printf '  %b[s]%b  Switch a site PHP version\n' "$BOLD" "$NC"
    printf '  %b[0]%b  Back\n'                      "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        i|install)
            printf '  Version to install (8.1 / 8.2 / 8.3 / 8.4): '
            read -r _ver
            if [[ -n "$_ver" ]]; then
                require_root; php_install_version "$_ver" || true; _mpause
            fi
            menu_php
            ;;
        s|switch)
            _sites_table
            printf '  %b[0]%b  Cancel\n' "$BOLD" "$NC"
            _mprompt "Select site #"
            if [[ "$MENU_INPUT" =~ ^[0-9]+$ ]] && \
               [[ $MENU_INPUT -ge 1 && $MENU_INPUT -le ${#MENU_SITES[@]} ]]; then
                _menu_php_switch "${MENU_SITES[$((MENU_INPUT-1))]}"
            fi
            menu_php
            ;;
        0|b|back) menu_root ;;
        *) menu_php ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Level 1 — SSL list
# ──────────────────────────────────────────────────────────────────────

menu_ssl_list() {
    local _conf _d _cert _exp _sel
    _mheader "SSL Certificates"
    printf '\n'
    printf '  %b%-30s  %-4s  %s%b\n' "$BOLD" "DOMAIN" "SSL" "EXPIRY" "$NC"
    _mhr

    if ls "$MWP_SITES_DIR"/*.conf &>/dev/null 2>&1; then
        for _conf in "$MWP_SITES_DIR"/*.conf; do
            [[ -f "$_conf" ]] || continue
            _d="$(grep "^DOMAIN=" "$_conf" | cut -d= -f2-)"
            _cert="/etc/letsencrypt/live/${_d}/fullchain.pem"
            if [[ -f "$_cert" ]]; then
                _exp="$(openssl x509 -enddate -noout -in "$_cert" 2>/dev/null | cut -d= -f2)"
                printf '  %-30s  %b✔%b   %s\n' "$_d" "$GREEN" "$NC" "$_exp"
            else
                printf '  %-30s  %b✗%b   —\n' "$_d" "$RED" "$NC"
            fi
        done
    fi
    _mhr
    printf '  %b[r]%b  Renew all (certbot)\n'       "$BOLD" "$NC"
    printf '  %b[s]%b  Manage SSL for a site\n'     "$BOLD" "$NC"
    printf '  %b[0]%b  Back\n'                      "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        r|renew)
            require_root; certbot renew --quiet || true
            log_success "Renewal attempt complete"
            _mpause; menu_ssl_list
            ;;
        s|select)
            _sites_table
            printf '  %b[0]%b  Cancel\n' "$BOLD" "$NC"
            _mprompt "Select site #"
            if [[ "$MENU_INPUT" =~ ^[0-9]+$ ]] && \
               [[ $MENU_INPUT -ge 1 && $MENU_INPUT -le ${#MENU_SITES[@]} ]]; then
                _menu_do_ssl "${MENU_SITES[$((MENU_INPUT-1))]}"
            fi
            menu_ssl_list
            ;;
        0|b|back) menu_root ;;
        *) menu_ssl_list ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Level 1 — Backups & Restore
# ──────────────────────────────────────────────────────────────────────

menu_backup() {
    local _conf _d
    _mheader "Backups & Restore"
    printf '\n'
    printf '  %b[1]%b  Backup all sites (full)\n'     "$BOLD" "$NC"
    printf '  %b[2]%b  Backup a specific site\n'      "$BOLD" "$NC"
    printf '  %b[3]%b  Restore a site from backup\n'  "$BOLD" "$NC"
    _mhr
    printf '  %b[0]%b  Back\n' "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1)
            _mc; printf '\n  Backing up all sites...\n\n'
            require_root
            for _conf in "$MWP_SITES_DIR"/*.conf; do
                [[ -f "$_conf" ]] || continue
                _d="$(grep "^DOMAIN=" "$_conf" | cut -d= -f2-)"
                backup_site "$_d" "full"
            done
            _mpause; menu_backup
            ;;
        2)
            _sites_table
            printf '  %b[0]%b  Cancel\n' "$BOLD" "$NC"
            _mprompt "Select site #"
            if [[ "$MENU_INPUT" =~ ^[0-9]+$ ]] && \
               [[ $MENU_INPUT -ge 1 && $MENU_INPUT -le ${#MENU_SITES[@]} ]]; then
                _menu_do_backup "${MENU_SITES[$((MENU_INPUT-1))]}"
            fi
            menu_backup
            ;;
        3)
            _sites_table
            printf '  %b[0]%b  Cancel\n' "$BOLD" "$NC"
            _mprompt "Select site #"
            if [[ "$MENU_INPUT" =~ ^[0-9]+$ ]] && \
               [[ $MENU_INPUT -ge 1 && $MENU_INPUT -le ${#MENU_SITES[@]} ]]; then
                _menu_do_restore "${MENU_SITES[$((MENU_INPUT-1))]}"
            fi
            menu_backup
            ;;
        0|b|back) menu_root ;;
        *) menu_backup ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Level 1 — Server status & tuning
# ──────────────────────────────────────────────────────────────────────

menu_server() {
    local _ip _ram _cpu _svc
    _mheader "Server Status & Tuning"
    printf '\n'
    printf '  %b[1]%b  Server status + all sites\n'  "$BOLD" "$NC"
    printf '  %b[2]%b  Retune PHP-FPM (apply)\n'     "$BOLD" "$NC"
    printf '  %b[3]%b  Retune preview (dry-run)\n'   "$BOLD" "$NC"
    _mhr
    printf '  %b[0]%b  Back\n' "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1)
            _mc
            _ip="$(server_get SERVER_IP 2>/dev/null || detect_ip)"
            _ram="$(detect_ram_mb)"
            _cpu="$(detect_cpu_cores)"
            printf '\n  %bServer%b\n' "$BOLD" "$NC"; _mhr
            printf '  IP:  %s\n  RAM: %sMB  │  CPU: %s cores\n' "$_ip" "$_ram" "$_cpu"
            printf '\n  %bServices%b\n' "$BOLD" "$NC"; _mhr
            for _svc in nginx mariadb redis-server; do
                if systemctl is-active --quiet "$_svc" 2>/dev/null; then
                    printf '  %b●%b  %-20s active\n'   "$GREEN" "$NC" "$_svc"
                else
                    printf '  %b●%b  %-20s inactive\n' "$RED"   "$NC" "$_svc"
                fi
            done
            _mhr
            registry_print_list
            _mpause; menu_server
            ;;
        2)
            _mc; require_root; tuning_retune_all; _mpause; menu_server
            ;;
        3)
            _mc; tuning_report; _mpause; menu_server
            ;;
        0|b|back) menu_root ;;
        *) menu_server ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Level 1 — Settings
# ──────────────────────────────────────────────────────────────────────

menu_settings() {
    local _pd _new_pd
    _pd="$(server_get PANEL_DOMAIN 2>/dev/null || printf '(not configured)')"

    _mheader "Settings"
    printf '\n'
    printf '  Panel domain:  %b%s%b\n' "$BOLD" "$_pd" "$NC"
    _mhr
    printf '  %b[1]%b  Set panel hostname (e.g. sv1.yourdomain.com)\n' "$BOLD" "$NC"
    printf '  %b[2]%b  Issue SSL for panel domain\n'                   "$BOLD" "$NC"
    _mhr
    printf '  %b[0]%b  Back\n' "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1)
            printf '  Panel hostname: '
            read -r _new_pd
            if [[ -n "$_new_pd" ]]; then
                if validate_domain "$_new_pd" 2>/dev/null; then
                    server_set "PANEL_DOMAIN" "$_new_pd"
                    log_success "Panel domain set: $_new_pd"
                else
                    log_warn "Invalid domain: $_new_pd"
                fi
                _mpause
            fi
            menu_settings
            ;;
        2)
            _pd="$(server_get PANEL_DOMAIN 2>/dev/null)"
            if [[ -z "$_pd" ]]; then
                log_warn "Panel domain not set. Configure it first ([1])."
                _mpause
            else
                _load_site_libs
                require_root
                ssl_issue "$_pd" || true
                _mpause
            fi
            menu_settings
            ;;
        0|b|back) menu_root ;;
        *) menu_settings ;;
    esac
}
