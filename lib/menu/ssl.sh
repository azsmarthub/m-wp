#!/usr/bin/env bash
# lib/menu/ssl.sh — SSL certificates list + per-site issue/check

[[ -n "${_MWP_MENU_SSL_LOADED:-}" ]] && return 0
_MWP_MENU_SSL_LOADED=1

menu_ssl_list() {
    local _conf _d _cert _exp _type _basename
    _mheader "SSL Certificates"
    printf '\n'
    printf '  %b%-30s  %-12s  %-4s  %s%b\n' "$BOLD" "DOMAIN" "TYPE" "SSL" "EXPIRY" "$NC"
    _mhr

    # Collect from BOTH /etc/mwp/sites and /etc/mwp/apps so apps show up too.
    for _conf in "$MWP_SITES_DIR"/*.conf "$MWP_APPS_DIR"/*.conf; do
        [[ -f "$_conf" ]] || continue
        _d="$(grep "^DOMAIN=" "$_conf" | cut -d= -f2-)"
        [[ -z "$_d" ]] && continue
        _cert=""; _type="—"
        if [[ -f "/etc/letsencrypt/live/${_d}/fullchain.pem" ]]; then
            _cert="/etc/letsencrypt/live/${_d}/fullchain.pem"
            _type="letsencrypt"
        elif [[ -f "/etc/mwp/ssl/${_d}/fullchain.pem" ]]; then
            _cert="/etc/mwp/ssl/${_d}/fullchain.pem"
            _type="self-signed"
        fi
        if [[ -n "$_cert" ]]; then
            _exp="$(openssl x509 -enddate -noout -in "$_cert" 2>/dev/null | cut -d= -f2)"
            printf '  %-30s  %-12s  %b✔%b   %s\n' "$_d" "$_type" "$GREEN" "$NC" "$_exp"
        else
            printf '  %-30s  %-12s  %b✗%b   —\n' "$_d" "—" "$RED" "$NC"
        fi
    done
    _mhr
    printf '  %b[r]%b  Renew all (certbot)\n'       "$BOLD" "$NC"
    printf '  %b[s]%b  Manage SSL for an entity\n'  "$BOLD" "$NC"
    printf '  %b[0]%b  Back\n'                      "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        r|renew)
            require_root; certbot renew --quiet || true
            log_success "Renewal attempt complete"
            _mpause; menu_ssl_list
            ;;
        s|select)
            _entities_table
            printf '  %b[0]%b  Cancel\n' "$BOLD" "$NC"
            _mprompt "Pick #"
            if [[ "$MENU_INPUT" =~ ^[0-9]+$ ]] && \
               [[ $MENU_INPUT -ge 1 && $MENU_INPUT -le ${#MENU_ENTITIES[@]} ]]; then
                local sel="${MENU_ENTITIES[$((MENU_INPUT-1))]}"
                local kind="${sel%%:*}" id="${sel#*:}"
                local domain="$id"
                # For apps, look up the domain from registry
                if [[ "$kind" == "app" ]]; then
                    [[ -n "${_MWP_APP_REGISTRY_LOADED:-}" ]] || \
                        source "$MWP_DIR/lib/app-registry.sh"
                    domain="$(app_get "$id" DOMAIN)"
                fi
                _menu_do_ssl "$domain"
            fi
            menu_ssl_list
            ;;
        0|b|back) menu_root ;;
        *) menu_ssl_list ;;
    esac
}
