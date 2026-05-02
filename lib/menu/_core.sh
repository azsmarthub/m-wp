#!/usr/bin/env bash
# lib/menu/_core.sh — Shared menu primitives + unified-entity helpers
#
# Loaded by lib/multi-menu.sh ahead of the per-area menu modules. Provides:
#   _mc / _mhr / _mhr2          screen/divider primitives
#   _mpause / _mprompt          input helpers
#   _mheader                    common screen header
#   _ssl_icon / _disk_usage     per-row data
#   _detect_framework           docroot inspection → WordPress/Laravel/Node/...
#   _entities_table             unified Sites + Apps + External listing
#
# Globals populated for selection-by-number:
#   MENU_ENTITIES[]   each item is "<kind>:<id>" — wp:<domain>, app:<name>,
#                     ext:<domain>. menu_sites uses this to route to the
#                     right detail screen (WP detail vs app detail vs ext info).
#   MENU_INPUT        last user input (lowercased)

[[ -n "${_MWP_MENU_CORE_LOADED:-}" ]] && return 0
_MWP_MENU_CORE_LOADED=1

MENU_ENTITIES=()
MENU_INPUT=""

# ──────────────────────────────────────────────────────────────────────
# UI primitives
# ──────────────────────────────────────────────────────────────────────

_mc()   { printf '\033[2J\033[H'; }
_mhr()  { printf '  ─────────────────────────────────────────────────────────────────\n'; }
_mhr2() { printf '  ═════════════════════════════════════════════════════════════════\n'; }

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
    local _ip _ram _cpu _site_n _app_n _def_php _svc _lbl
    _ip="$(server_get SERVER_IP 2>/dev/null)"; [[ -z "$_ip" ]] && _ip="$(detect_ip)"
    _ram="$(detect_ram_mb)"
    _cpu="$(detect_cpu_cores)"
    _site_n="$(site_count 2>/dev/null || echo 0)"
    _app_n=0
    if [[ -d "$MWP_APPS_DIR" ]]; then
        for _conf in "$MWP_APPS_DIR"/*.conf; do
            [[ -f "$_conf" ]] && _app_n=$(( _app_n + 1 ))
        done
    fi
    _def_php="$(server_get DEFAULT_PHP 2>/dev/null)"
    [[ -z "$_def_php" ]] && _def_php="8.5"

    _mc
    _mhr2
    if [[ -n "$subtitle" ]]; then
        printf '  %bmwp%b  ──  %b%s%b\n' "$BOLD" "$NC" "$BOLD" "$subtitle" "$NC"
    else
        printf '  %bmwp%b v%s\n' "$BOLD" "$NC" "$MWP_VERSION"
    fi
    printf '  %s  │  RAM: %sMB  │  CPU: %s  │  Sites: %s  │  Apps: %s\n' \
        "$_ip" "$_ram" "$_cpu" "$_site_n" "$_app_n"
    printf '  '
    for _svc in nginx mariadb redis-server "php${_def_php}-fpm" docker; do
        _lbl="$_svc"
        [[ "$_svc" == "redis-server" ]] && _lbl="redis"
        # Docker is optional — show as dim "—" if not installed
        if [[ "$_svc" == "docker" ]] && ! command -v docker >/dev/null 2>&1; then
            printf '%bdocker —%b  ' "$DIM" "$NC"
            continue
        fi
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
# Per-row helpers
# ──────────────────────────────────────────────────────────────────────

_ssl_icon() {
    local _dom="$1"
    local _cert=""
    [[ -f "/etc/letsencrypt/live/${_dom}/fullchain.pem" ]] && _cert="/etc/letsencrypt/live/${_dom}/fullchain.pem"
    [[ -f "/etc/mwp/ssl/${_dom}/fullchain.pem"          ]] && _cert="/etc/mwp/ssl/${_dom}/fullchain.pem"
    [[ -z "$_cert" ]] && printf '✗' && return

    local _exp _now
    _exp="$(openssl x509 -enddate -noout -in "$_cert" 2>/dev/null \
            | cut -d= -f2 | xargs -I{} date -d '{}' +%s 2>/dev/null)" || _exp=0
    _now="$(date +%s)"
    [[ ${_exp:-0} -gt $_now ]] && printf '✔' || printf '!'
}

_disk_usage() {
    local _u="$1"
    [[ -z "$_u" ]] && { printf '-'; return; }
    if [[ -d "/home/${_u}" ]]; then
        du -sh "/home/${_u}" 2>/dev/null | cut -f1
    elif [[ -d "/var/lib/mwp/apps/${_u}" ]]; then
        du -sh "/var/lib/mwp/apps/${_u}" 2>/dev/null | cut -f1
    else
        printf '-'
    fi
}

# ──────────────────────────────────────────────────────────────────────
# Framework detection — inspect docroot for tell-tale files. Used by both
# WP-site rows (so a site whose WP install was replaced shows the new
# framework) and external-vhost rows.
# ──────────────────────────────────────────────────────────────────────

_detect_framework() {
    local doc_root="$1"
    [[ -z "$doc_root" || ! -d "$doc_root" ]] && { printf 'Unknown'; return; }

    if [[ -f "$doc_root/wp-config.php" || -f "$doc_root/wp-config-sample.php" ]]; then
        printf 'WordPress'; return
    fi
    if [[ -f "$doc_root/artisan" ]]; then
        printf 'Laravel'; return
    fi
    if [[ -f "$doc_root/package.json" ]]; then
        if grep -q '"next"'  "$doc_root/package.json" 2>/dev/null; then printf 'Next.js'; return; fi
        if grep -q '"nuxt"'  "$doc_root/package.json" 2>/dev/null; then printf 'Nuxt';    return; fi
        if grep -q '"react"' "$doc_root/package.json" 2>/dev/null; then printf 'React';   return; fi
        printf 'Node'; return
    fi
    if [[ -f "$doc_root/composer.json" ]]; then
        if grep -q 'symfony/framework-bundle' "$doc_root/composer.json" 2>/dev/null; then printf 'Symfony'; return; fi
        printf 'PHP'; return
    fi
    if [[ -f "$doc_root/manage.py" ]]; then printf 'Django'; return; fi
    if [[ -f "$doc_root/Gemfile"   ]]; then printf 'Rails';  return; fi
    if [[ -f "$doc_root/index.html" || -f "$doc_root/index.htm" ]]; then
        printf 'Static'; return
    fi
    printf 'Custom'
}

# Short label for a Docker image — strip registry/tag, keep only the
# project name (e.g. "ghcr.io/user/n8nio/n8n:1.74" → "n8n").
_short_image() {
    local img="$1"
    img="${img%:*}"            # strip tag
    img="${img##*/}"           # keep only last path segment
    [[ -z "$img" ]] && img="?"
    printf 'Docker:%s' "$img"
}

# ──────────────────────────────────────────────────────────────────────
# External vhost scan — find nginx vhosts NOT registered to a WP site
# or a Docker app. Outputs lines: "<domain>|<doc_root>|<framework>".
# Guards against double-counting by building a hash of all managed
# domains (WP + app) first.
# ──────────────────────────────────────────────────────────────────────

_scan_external_vhosts() {
    local conf basename d root managed_domains=""
    # Build managed-domain lookup (space-padded for fast `case` match)
    if [[ -d "$MWP_SITES_DIR" ]]; then
        for conf in "$MWP_SITES_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            d="$(grep "^DOMAIN=" "$conf" | cut -d= -f2-)"
            [[ -n "$d" ]] && managed_domains+=" $d"
        done
    fi
    if [[ -d "$MWP_APPS_DIR" ]]; then
        for conf in "$MWP_APPS_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            d="$(grep "^DOMAIN=" "$conf" | cut -d= -f2-)"
            [[ -n "$d" ]] && managed_domains+=" $d"
        done
    fi
    managed_domains+=" "

    [[ -d /etc/nginx/sites-enabled ]] || return 0
    for conf in /etc/nginx/sites-enabled/*.conf; do
        [[ -f "$conf" ]] || continue
        basename="$(basename "$conf" .conf)"
        case "$basename" in
            default|*_placeholder|*-placeholder|mwp-panel) continue ;;
        esac
        # Pull first server_name + first root directive
        d="$(grep -m1 -oE 'server_name\s+[^;]+' "$conf" 2>/dev/null \
             | awk '{print $2}' | head -1)"
        [[ -z "$d" || "$d" == "_" ]] && d="$basename"
        # Skip if this domain is in either registry
        case "$managed_domains" in *" $d "*) continue ;; esac
        root="$(grep -m1 -oE 'root\s+[^;]+' "$conf" 2>/dev/null \
                | awk '{print $2}' | head -1)"
        printf '%s|%s|%s\n' "$d" "${root:-}" "$(_detect_framework "${root:-}")"
    done
}

# ──────────────────────────────────────────────────────────────────────
# Unified entity table. Shows WP sites + Docker apps + External vhosts
# in one list with TYPE column. Populates MENU_ENTITIES[] with prefixed
# IDs so menu_sites can route the user's selection to the right detail.
#
# Args: optional filter substring — matched against domain.
# ──────────────────────────────────────────────────────────────────────

_entities_table() {
    local filter="${1:-}"
    local _conf _d _st _php _su _ssl _disk _st_col _idx _type _img _port
    MENU_ENTITIES=()
    _idx=0

    printf '\n'
    printf '  %b%-3s  %-30s  %-12s  %-9s  %-7s  %-3s  %s%b\n' \
        "$BOLD" "#" "DOMAIN" "TYPE" "STATUS" "PHP/PORT" "SSL" "DISK" "$NC"
    _mhr

    # ─── 1) WordPress sites ─────────────────────────────────────────
    if [[ -d "$MWP_SITES_DIR" ]] && ls "$MWP_SITES_DIR"/*.conf &>/dev/null 2>&1; then
        for _conf in "$MWP_SITES_DIR"/*.conf; do
            [[ -f "$_conf" ]] || continue
            _d="$(grep   "^DOMAIN="      "$_conf" | cut -d= -f2-)"
            _st="$(grep  "^STATUS="      "$_conf" | cut -d= -f2-)"
            _php="$(grep "^PHP_VERSION=" "$_conf" | cut -d= -f2-)"
            _su="$(grep  "^SITE_USER="   "$_conf" | cut -d= -f2-)"
            local _wr
            _wr="$(grep  "^WEB_ROOT="    "$_conf" | cut -d= -f2-)"

            [[ -n "$filter" && "$_d" != *"$filter"* ]] && continue

            _idx=$(( _idx + 1 ))
            MENU_ENTITIES+=("wp:$_d")
            _ssl="$(_ssl_icon "$_d")"
            _disk="$(_disk_usage "$_su")"
            _type="$(_detect_framework "$_wr")"

            case "$_st" in
                active)   _st_col="$(printf '%bactive   %b' "$GREEN" "$NC")" ;;
                disabled) _st_col="$(printf '%bdisabled %b' "$RED"   "$NC")" ;;
                *)        _st_col="$(printf '%b%-9s%b'      "$BOLD"  "$_st" "$NC")" ;;
            esac

            printf '  %b%-3s%b  %-30s  %-12s  %s  %-7s  %-3s  %s\n' \
                "$BOLD" "$_idx" "$NC" "$_d" "$_type" "$_st_col" "$_php" "$_ssl" "$_disk"
        done
    fi

    # ─── 2) Docker apps ─────────────────────────────────────────────
    if [[ -d "$MWP_APPS_DIR" ]] && ls "$MWP_APPS_DIR"/*.conf &>/dev/null 2>&1; then
        for _conf in "$MWP_APPS_DIR"/*.conf; do
            [[ -f "$_conf" ]] || continue
            local _name _container _live="?"
            _name="$(basename "$_conf" .conf)"
            _d="$(grep   "^DOMAIN="    "$_conf" | cut -d= -f2-)"
            _img="$(grep "^IMAGE="     "$_conf" | cut -d= -f2-)"
            _port="$(grep "^HOST_PORT=" "$_conf" | cut -d= -f2-)"
            _container="$(grep "^CONTAINER=" "$_conf" | cut -d= -f2-)"

            [[ -n "$filter" && "$_d" != *"$filter"* && "$_name" != *"$filter"* ]] && continue

            _idx=$(( _idx + 1 ))
            MENU_ENTITIES+=("app:$_name")

            # Live container state via docker (best-effort)
            if command -v docker >/dev/null 2>&1 && [[ -n "$_container" ]]; then
                if docker ps --filter "name=^${_container}$" --format '{{.Names}}' 2>/dev/null | grep -q .; then
                    _live="running"
                elif docker ps -a --filter "name=^${_container}$" --format '{{.Names}}' 2>/dev/null | grep -q .; then
                    _live="stopped"
                else
                    _live="missing"
                fi
            fi
            case "$_live" in
                running) _st_col="$(printf '%brunning  %b' "$GREEN"  "$NC")" ;;
                stopped) _st_col="$(printf '%bstopped  %b' "$YELLOW" "$NC")" ;;
                missing) _st_col="$(printf '%bmissing  %b' "$RED"    "$NC")" ;;
                *)       _st_col="$(printf '%b%-9s%b'      "$BOLD"   "$_live" "$NC")" ;;
            esac

            _ssl="$(_ssl_icon "$_d")"
            _disk="$(_disk_usage "$_name")"
            _type="$(_short_image "$_img")"

            # Use HOST_PORT in the PHP/PORT column for apps
            printf '  %b%-3s%b  %-30s  %-12s  %s  %-7s  %-3s  %s\n' \
                "$BOLD" "$_idx" "$NC" "$_d" "$_type" "$_st_col" ":$_port" "$_ssl" "$_disk"
        done
    fi

    # ─── 3) External nginx vhosts (not in either registry) ─────────
    while IFS='|' read -r _d _root _type; do
        [[ -z "$_d" ]] && continue
        [[ -n "$filter" && "$_d" != *"$filter"* ]] && continue
        _idx=$(( _idx + 1 ))
        MENU_ENTITIES+=("ext:$_d")
        _ssl="$(_ssl_icon "$_d")"
        _disk="-"
        _st_col="$(printf '%bextern. %b' "$DIM" "$NC")"
        printf '  %b%-3s%b  %-30s  %-12s  %s  %-7s  %-3s  %s\n' \
            "$BOLD" "$_idx" "$NC" "$_d" "${_type:-Unknown}" "$_st_col" "—" "$_ssl" "$_disk"
    done < <(_scan_external_vhosts)

    _mhr
    if [[ $_idx -eq 0 ]]; then
        if [[ -n "$filter" ]]; then
            printf '  (no entities match: "%s")\n' "$filter"
        else
            printf '  (no sites or apps yet — press [c] to create)\n'
        fi
        _mhr
    fi
    return 0
}

# Legacy-name alias (kept so older menu callers keep working until fully
# migrated). New code should call _entities_table directly.
_sites_table() { _entities_table "$@"; MENU_SITES=("${MENU_ENTITIES[@]##*:}"); }
MENU_SITES=()
