#!/usr/bin/env bash
# lib/menu/settings.sh — server-level settings (panel domain, defaults)

[[ -n "${_MWP_MENU_SETTINGS_LOADED:-}" ]] && return 0
_MWP_MENU_SETTINGS_LOADED=1

menu_settings() {
    local _pd _new_pd _def_php
    _pd="$(server_get PANEL_DOMAIN 2>/dev/null)"
    [[ -z "$_pd" ]] && _pd="(not configured)"
    _def_php="$(server_get DEFAULT_PHP 2>/dev/null)"
    [[ -z "$_def_php" ]] && _def_php="8.5"

    _mheader "Settings"
    printf '\n'
    printf '  Panel domain:  %b%s%b\n' "$BOLD" "$_pd" "$NC"
    printf '  Default PHP:   %b%s%b\n' "$BOLD" "$_def_php" "$NC"
    _mhr
    printf '  %b[1]%b  Set panel hostname (e.g. sv1.yourdomain.com)\n' "$BOLD" "$NC"
    printf '  %b[2]%b  Issue SSL for panel domain\n'                   "$BOLD" "$NC"
    printf '  %b[3]%b  Set default PHP version for new sites\n'        "$BOLD" "$NC"
    printf '  %b[4]%b  View /etc/mwp/server.conf\n'                    "$BOLD" "$NC"
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
        3)
            php_list_versions
            printf '  New default version: '
            local _v; read -r _v
            if [[ -n "$_v" ]]; then
                server_set "DEFAULT_PHP" "$_v"
                log_success "Default PHP set: $_v (applies to NEW sites only)"
                _mpause
            fi
            menu_settings
            ;;
        4)
            _mc
            printf '\n  %b/etc/mwp/server.conf%b\n\n' "$BOLD" "$NC"
            if [[ -f "$MWP_SERVER_CONF" ]]; then
                # Mask DB_ROOT_PASS so it doesn't leak to terminal scrollback
                sed 's/^\(DB_ROOT_PASS=\).*/\1***hidden***/' "$MWP_SERVER_CONF"
            else
                printf '  (file does not exist)\n'
            fi
            _mpause; menu_settings
            ;;
        0|b|back) menu_root ;;
        *) menu_settings ;;
    esac
}
