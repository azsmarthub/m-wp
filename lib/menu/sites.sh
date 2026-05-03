#!/usr/bin/env bash
# lib/menu/sites.sh — Sites & Apps menu (Level 1) + WP-site detail (Level 2)
#
# This is the unified entry point for ALL hosted entities. menu_sites shows
# WP sites, Docker apps, and external nginx vhosts in one table; selecting
# any of them dispatches to the right detail screen:
#   wp:<domain>   → menu_site_detail
#   app:<name>    → menu_app_detail   (defined in lib/menu/apps.sh)
#   ext:<domain>  → menu_external_detail

[[ -n "${_MWP_MENU_SITES_LOADED:-}" ]] && return 0
_MWP_MENU_SITES_LOADED=1

# ──────────────────────────────────────────────────────────────────────
# Level 1 — Sites & Apps list (unified)
# ──────────────────────────────────────────────────────────────────────

menu_sites() {
    local filter="${1:-}"
    local _new_dom _kw _sel _kind _id

    _mheader "Sites & Apps"
    [[ -n "$filter" ]] && printf '  Filter: %b%s%b\n' "$BOLD" "$filter" "$NC"
    _entities_table "$filter"

    printf '  %b[c]%b New WP site   %b[a]%b New Docker app' "$BOLD" "$NC" "$BOLD" "$NC"
    [[ -n "$filter" ]] && printf '   %b[x]%b Clear filter' "$BOLD" "$NC"
    printf '   %b[/]%b Filter   %b[0]%b Back\n' "$BOLD" "$NC" "$BOLD" "$NC"
    _mprompt "Pick # or action"

    case "$MENU_INPUT" in
        0|b|back)
            menu_root; return
            ;;
        c|create)
            _mc
            printf '\n  %bCreate new WordPress site%b\n' "$BOLD" "$NC"
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
        a|app)
            # Hand off to apps.sh wizard — it handles its own prompts
            _menu_app_create_wizard
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
               [[ $MENU_INPUT -ge 1 && $MENU_INPUT -le ${#MENU_ENTITIES[@]} ]]; then
                _sel="${MENU_ENTITIES[$((MENU_INPUT-1))]}"
                _kind="${_sel%%:*}"
                _id="${_sel#*:}"
                case "$_kind" in
                    wp)  menu_site_detail     "$_id" ;;
                    app) menu_app_detail      "$_id" ;;
                    ext) menu_external_detail "$_id" ;;
                esac
                menu_sites "$filter"
            else
                menu_sites "$filter"
            fi
            ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Level 2 — WP site detail
# ──────────────────────────────────────────────────────────────────────

menu_site_detail() {
    local domain="$1"
    site_exists "$domain" || { log_warn "Site '$domain' not found."; return; }

    local _st _php _su _webroot _db _rdb _ssl _disk _toggle _st_col _type
    _st="$(site_get "$domain" STATUS)"
    _php="$(site_get "$domain" PHP_VERSION)"
    _su="$(site_get "$domain" SITE_USER)"
    _webroot="$(site_get "$domain" WEB_ROOT)"
    _db="$(site_get "$domain" DB_NAME)"
    _rdb="$(site_get "$domain" REDIS_DB)"
    _ssl="$(_ssl_icon "$domain")"
    _disk="$(_disk_usage "$_su")"
    _type="$(_detect_framework "$_webroot")"
    [[ "$_st" == "active" ]] && _toggle="Disable" || _toggle="Enable"
    [[ "$_st" == "active" ]] \
        && _st_col="$(printf '%b%s%b' "$GREEN" "$_st" "$NC")" \
        || _st_col="$(printf '%b%s%b' "$RED"   "$_st" "$NC")"

    _mheader "$domain"
    printf '\n'
    printf '  Type: %s  │  Status: %s  │  PHP: %s  │  SSL: %s  │  Disk: %s\n' \
        "$_type" "$_st_col" "$_php" "$_ssl" "$_disk"
    printf '  User: %s  │  DB: %s  │  Redis DB: %s\n' "$_su" "$_db" "$_rdb"
    printf '  Root: %s\n' "$_webroot"
    _mhr
    printf '\n'
    printf '  %b[1]%b  Info & details          %b[6]%b  Restore from backup\n'  "$BOLD" "$NC" "$BOLD" "$NC"
    printf '  %b[2]%b  %-8s site          %b[7]%b  Check isolation\n'           "$BOLD" "$NC" "$_toggle" "$BOLD" "$NC"
    printf '  %b[3]%b  Switch PHP version      %b[8]%b  Enter site shell\n'     "$BOLD" "$NC" "$BOLD" "$NC"
    printf '  %b[4]%b  Purge cache             %b[9]%b  SSL manage\n'           "$BOLD" "$NC" "$BOLD" "$NC"
    printf '  %b[5]%b  Backup                  %b[L]%b  Magic-login URL (24h)\n' "$BOLD" "$NC" "$BOLD" "$NC"
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
            if [[ "$_st" == "active" ]]; then site_disable "$domain"
            else                              site_enable  "$domain"
            fi
            _mpause; menu_site_detail "$domain"
            ;;
        3) _menu_php_switch "$domain"; menu_site_detail "$domain" ;;
        4)
            _mc; printf '\n  Purging cache for %s...\n' "$domain"
            cache_purge_site "$domain"; _mpause
            menu_site_detail "$domain"
            ;;
        5) _menu_do_backup  "$domain"; menu_site_detail "$domain" ;;
        6) _menu_do_restore "$domain"; menu_site_detail "$domain" ;;
        7) _mc; isolation_check "$domain"; _mpause; menu_site_detail "$domain" ;;
        8)
            printf '\n  %bEntering shell for user: %s%b\n' "$BOLD" "$_su" "$NC"
            printf '  Type "exit" to return to mwp.\n\n'
            su -s /bin/bash - "$_su" || true
            menu_site_detail "$domain"
            ;;
        9) _menu_do_ssl "$domain"; menu_site_detail "$domain" ;;
        l|L|login)
            _mc; require_root; site_magic_login "$domain"; _mpause
            menu_site_detail "$domain"
            ;;
        d|delete)
            require_root
            site_delete "$domain" || true
            return
            ;;
        0|b|back) return ;;
        *) menu_site_detail "$domain" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Level 2 — External vhost detail (read-only inspection)
# Anything in /etc/nginx/sites-enabled that isn't an mwp site or app —
# could be a hand-rolled Laravel/Static/etc. We don't manage it (no DB,
# no PHP pool, no isolation) but we let the operator see + disable it.
# ──────────────────────────────────────────────────────────────────────

menu_external_detail() {
    local domain="$1"
    local conf="/etc/nginx/sites-enabled/${domain}.conf"
    local conf_real="/etc/nginx/sites-available/${domain}.conf"
    if [[ ! -f "$conf" && ! -f "$conf_real" ]]; then
        # The "domain" we have might not match the filename. Try first conf
        # whose server_name contains it.
        for f in /etc/nginx/sites-enabled/*.conf; do
            [[ -f "$f" ]] || continue
            if grep -qE "server_name\s+[^;]*\b${domain}\b" "$f" 2>/dev/null; then
                conf="$f"; conf_real="$f"; break
            fi
        done
    fi

    local root framework enabled="yes"
    root="$(grep -m1 -oE 'root\s+[^;]+' "$conf" 2>/dev/null | awk '{print $2}')"
    framework="$(_detect_framework "$root")"
    [[ -L "$conf" ]] || enabled="symlink missing"

    _mheader "$domain  (external)"
    printf '\n'
    printf '  Type:     %s  (detected from %s)\n' "$framework" "${root:-?}"
    printf '  Vhost:    %s\n' "$conf"
    printf '  Enabled:  %s\n' "$enabled"
    [[ -n "$root" ]] && printf '  Disk:     %s\n' "$(du -sh "$root" 2>/dev/null | cut -f1 || echo '-')"
    _mhr
    printf '\n'
    printf '  %b[1]%b  View nginx vhost config\n'  "$BOLD" "$NC"
    printf '  %b[2]%b  View nginx error log\n'      "$BOLD" "$NC"
    printf '  %b[3]%b  Disable (unlink from sites-enabled)\n'  "$BOLD" "$NC"
    printf '  %b[4]%b  Issue / refresh SSL\n'       "$BOLD" "$NC"
    _mhr
    printf '  %b[0]%b  Back\n' "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1) _mc; less -R "$conf" 2>/dev/null || cat "$conf"; _mpause ;;
        2)
            local elog="/var/log/nginx/error.log"
            _mc; tail -200 "$elog" 2>/dev/null || log_warn "no error.log"; _mpause
            ;;
        3)
            require_root
            if [[ -L "$conf" ]]; then
                rm -f "$conf"
                nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null
                log_success "Disabled: $conf"
            else
                log_warn "Not a symlink (already disabled or static config)."
            fi
            _mpause; return
            ;;
        4)
            _load_site_libs
            require_root
            ssl_issue "$domain" || true
            _mpause; menu_external_detail "$domain"
            ;;
        0|b|back) return ;;
        *) menu_external_detail "$domain" ;;
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
    printf '  New version (8.1 / 8.2 / 8.3 / 8.4 / 8.5 — or ENTER to cancel): '
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
    local _cert="" _type="none"
    if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
        _cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
        _type="Let's Encrypt"
    elif [[ -f "/etc/mwp/ssl/${domain}/fullchain.pem" ]]; then
        _cert="/etc/mwp/ssl/${domain}/fullchain.pem"
        _type="self-signed (Cloudflare)"
    fi
    local _exp

    _mc
    printf '\n  %bSSL — %s%b\n' "$BOLD" "$domain" "$NC"
    _mhr
    if [[ -n "$_cert" ]]; then
        _exp="$(openssl x509 -enddate -noout -in "$_cert" 2>/dev/null | cut -d= -f2)"
        printf '  Type:         %s\n' "$_type"
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
        1) require_root; ssl_issue "$domain" || true; _mpause ;;
        2)
            echo | openssl s_client -connect "${domain}:443" -servername "$domain" 2>/dev/null \
                | openssl x509 -noout -dates 2>/dev/null \
                || log_warn "SSL connection failed or no certificate."
            _mpause
            ;;
        *) return ;;
    esac
}
