#!/usr/bin/env bash
# lib/menu/php.sh — PHP versions menu

[[ -n "${_MWP_MENU_PHP_LOADED:-}" ]] && return 0
_MWP_MENU_PHP_LOADED=1

menu_php() {
    local _ver
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
            printf '  Version to install (8.1 / 8.2 / 8.3 / 8.4 / 8.5): '
            read -r _ver
            if [[ -n "$_ver" ]]; then
                require_root; php_install_version "$_ver" || true; _mpause
            fi
            menu_php
            ;;
        s|switch)
            _entities_table
            printf '  %b[0]%b  Cancel\n' "$BOLD" "$NC"
            _mprompt "Pick site #"
            if [[ "$MENU_INPUT" =~ ^[0-9]+$ ]] && \
               [[ $MENU_INPUT -ge 1 && $MENU_INPUT -le ${#MENU_ENTITIES[@]} ]]; then
                local sel="${MENU_ENTITIES[$((MENU_INPUT-1))]}"
                local kind="${sel%%:*}" id="${sel#*:}"
                if [[ "$kind" == "wp" ]]; then
                    _menu_php_switch "$id"
                else
                    log_warn "PHP switch only applies to WordPress sites."
                    _mpause
                fi
            fi
            menu_php
            ;;
        0|b|back) menu_root ;;
        *) menu_php ;;
    esac
}
