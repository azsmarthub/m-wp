#!/usr/bin/env bash
# multi/menu.sh — mwp CLI
# Usage: mwp <command> [args]

set -euo pipefail

# Follow symlink to real script location
_SELF="${BASH_SOURCE[0]}"
while [[ -L "$_SELF" ]]; do
    _DIR="$(cd "$(dirname "$_SELF")" && pwd)"
    _SELF="$(readlink "$_SELF")"
    [[ "$_SELF" != /* ]] && _SELF="$_DIR/$_SELF"
done
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
MWP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export MWP_DIR

source "$MWP_DIR/lib/common.sh"
source "$MWP_DIR/lib/registry.sh"

# Load per-site libs lazily
_load_site_libs() {
    for _lib in nginx php site ssl backup isolation tuning; do
        local f="$MWP_DIR/lib/multi-${_lib}.sh"
        [[ -f "$f" ]] && source "$f"
    done
}

# Load interactive menu lib lazily
_load_menu_lib() {
    source "$MWP_DIR/lib/multi-menu.sh"
}

mwp_init
trap 'trap_error $LINENO "$BASH_COMMAND"' ERR

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
cmd_help() {
    cat <<HELP

${BOLD}mwp${NC} — Multi-site WordPress CLI v${MWP_VERSION}

${BOLD}Usage:${NC}
  mwp <command> [args]

${BOLD}Site management:${NC}
  mwp sites                        List all sites
  mwp site create <domain>         Create new WordPress site
  mwp site delete <domain>         Delete site (with confirm)
  mwp site info   <domain>         Show site details
  mwp site enable  <domain>        Enable disabled site
  mwp site disable <domain>        Disable site (keeps files)
  mwp site shell   <domain>        Enter site user shell
  mwp site check-isolation <domain> Audit isolation layers

${BOLD}PHP:${NC}
  mwp php list                     List installed PHP versions
  mwp php install <version>        Install PHP version (8.1/8.2/8.3/8.4/8.5)
  mwp php switch  <domain> <ver>   Switch site PHP version

${BOLD}Cache:${NC}
  mwp cache purge  <domain>        Purge FastCGI + Redis cache for site
  mwp cache purge-all              Purge all sites

${BOLD}SSL:${NC}
  mwp ssl issue  <domain>          Issue Let's Encrypt certificate
  mwp ssl renew                    Renew all certificates
  mwp ssl status <domain>          Show SSL expiry

${BOLD}Backup:${NC}
  mwp backup full <domain>         Full backup (files + DB)
  mwp backup db   <domain>         Database-only backup
  mwp backup all                   Backup all sites
  mwp restore     <domain> <file>  Restore from backup

${BOLD}Server:${NC}
  mwp status                       Server + all sites overview
  mwp status <domain>              Single site status
  mwp retune                       Recalculate + apply FPM pools for all sites
  mwp retune --dry-run             Show what retune would change
  mwp panel info                   Show panel URL info
  mwp panel setup                  Configure panel hostname (sv1.yourdomain.com)
  mwp panel ssl                    Issue SSL for panel domain

${BOLD}Examples:${NC}
  mwp site create example.com
  mwp php switch example.com 8.2
  mwp cache purge example.com
  mwp backup full example.com

HELP
}

# ---------------------------------------------------------------------------
# Status overview
# ---------------------------------------------------------------------------
cmd_status() {
    local domain="${1:-}"

    if [[ -n "$domain" ]]; then
        site_exists "$domain" || die "Site '$domain' not found."
        registry_print_info "$domain"

        # Live service check
        local php_ver
        php_ver="$(site_get "$domain" PHP_VERSION)"
        printf '  %bLive status:%b\n' "$BOLD" "$NC"
        for svc in nginx "php${php_ver}-fpm" mariadb redis-server; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                printf '  %b●%b  %s\n' "$GREEN" "$NC" "$svc"
            else
                printf '  %b●%b  %s (inactive)\n' "$RED" "$NC" "$svc"
            fi
        done
        printf '\n'
        return
    fi

    # Server overview
    local ram_mb cpu server_ip
    ram_mb="$(detect_ram_mb)"
    cpu="$(detect_cpu_cores)"
    server_ip="$(detect_ip)"
    local site_count
    site_count="$(site_count)"

    printf '\n%b  mwp Server Overview%b\n' "$BOLD" "$NC"
    printf '  %s\n' "──────────────────────────────────────────"
    printf '  IP:        %s\n' "$server_ip"
    printf '  RAM:       %sMB  CPU: %s core(s)\n' "$ram_mb" "$cpu"
    printf '  Sites:     %s\n' "$site_count"
    printf '\n'

    # Services
    printf '%b  Services:%b\n' "$BOLD" "$NC"
    for svc in nginx mariadb redis-server; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            printf '  %b●%b  %-20s active\n' "$GREEN" "$NC" "$svc"
        else
            printf '  %b●%b  %-20s inactive\n' "$RED" "$NC" "$svc"
        fi
    done
    printf '\n'

    # Sites list
    if [[ $site_count -gt 0 ]]; then
        registry_print_list
    fi
}

# ---------------------------------------------------------------------------
# Site commands
# ---------------------------------------------------------------------------
cmd_site() {
    local sub="${1:-}"
    shift || true

    # Known direct subcommands — handle non-interactively
    case "$sub" in
        create|delete|info|enable|disable|shell|check-isolation) ;;
        *)
            # No subcommand or unrecognised → interactive menu
            # Treat $sub as a filter string (e.g. "mwp site do1" filters by "do1")
            _load_site_libs
            _load_menu_lib
            menu_sites "$sub"
            return
            ;;
    esac

    _load_site_libs

    case "$sub" in
        create)  require_root; site_create "${1:-}" ;;
        delete)  require_root; site_delete "${1:-}" ;;
        info)    registry_print_info "${1:-}" ;;
        enable)  require_root; site_enable "${1:-}" ;;
        disable) require_root; site_disable "${1:-}" ;;
        check-isolation)
            isolation_check "${1:-}"
            ;;
        shell)
            local domain="${1:-}"
            site_exists "$domain" || die "Site '$domain' not found."
            local user
            user="$(site_get "$domain" SITE_USER)"
            # Site user shell is /usr/sbin/nologin (security), override with bash
            exec su -s /bin/bash - "$user"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# PHP commands
# ---------------------------------------------------------------------------
cmd_php() {
    local sub="${1:-}"
    shift || true
    _load_site_libs

    case "$sub" in
        list)    php_list_versions ;;
        install) require_root; php_install_version "${1:-}" ;;
        switch)  require_root; php_switch_site "${1:-}" "${2:-}" ;;
        *) cmd_help; die "Unknown php subcommand: $sub" ;;
    esac
}

# ---------------------------------------------------------------------------
# Cache commands
# ---------------------------------------------------------------------------
cmd_cache() {
    local sub="${1:-}"
    shift || true
    _load_site_libs

    case "$sub" in
        purge)
            local domain="${1:-}"
            site_exists "$domain" || die "Site '$domain' not found."
            cache_purge_site "$domain"
            ;;
        purge-all)
            local conf
            for conf in "$MWP_SITES_DIR"/*.conf; do
                [[ -f "$conf" ]] || continue
                local d
                d="$(grep "^DOMAIN=" "$conf" | cut -d= -f2-)"
                cache_purge_site "$d" && log_success "Purged: $d"
            done
            ;;
        *) cmd_help; die "Unknown cache subcommand: $sub" ;;
    esac
}

# ---------------------------------------------------------------------------
# SSL commands
# ---------------------------------------------------------------------------
cmd_ssl() {
    local sub="${1:-}"
    shift || true
    _load_site_libs

    case "$sub" in
        issue)  require_root; ssl_issue "${1:-}" ;;
        renew)  require_root; certbot renew --quiet ;;
        status)  ssl_status "${1:-}" ;;
        *) cmd_help; die "Unknown ssl subcommand: $sub" ;;
    esac
}

# ---------------------------------------------------------------------------
# Backup commands
# ---------------------------------------------------------------------------
cmd_backup() {
    local sub="${1:-}"
    shift || true
    _load_site_libs

    case "$sub" in
        full) require_root; backup_site "${1:-}" "full" ;;
        db)   require_root; backup_site "${1:-}" "db" ;;
        all)
            require_root
            local conf
            for conf in "$MWP_SITES_DIR"/*.conf; do
                [[ -f "$conf" ]] || continue
                local d
                d="$(grep "^DOMAIN=" "$conf" | cut -d= -f2-)"
                backup_site "$d" "full"
            done
            ;;
        *) cmd_help; die "Unknown backup subcommand: $sub" ;;
    esac
}

cmd_restore() {
    require_root
    _load_site_libs
    restore_site "${1:-}" "${2:-}"
}

# ---------------------------------------------------------------------------
# Router
# ---------------------------------------------------------------------------
main() {
    local cmd="${1:-}"
    shift || true

    # No command → launch interactive root menu
    if [[ -z "$cmd" ]]; then
        _load_site_libs
        _load_menu_lib
        menu_root
        return
    fi

    case "$cmd" in
        help|--help|-h) cmd_help ;;
        version|--version|-v) printf 'mwp v%s\n' "$MWP_VERSION" ;;
        status)  cmd_status "$@" ;;
        sites)
            _load_site_libs; _load_menu_lib; menu_sites "${1:-}"
            ;;
        site)    cmd_site "$@" ;;
        php)     cmd_php "$@" ;;
        cache)   cmd_cache "$@" ;;
        ssl)     cmd_ssl "$@" ;;
        backup)  cmd_backup "$@" ;;
        restore) cmd_restore "$@" ;;
        panel)
            local sub="${1:-info}"
            case "$sub" in
                info)
                    local pd
                    pd="$(server_get "PANEL_DOMAIN" 2>/dev/null)"
                    printf '\n%b  mwp Panel URL%b\n' "$BOLD" "$NC"
                    printf '  %s\n' "──────────────────────────────────"
                    if [[ -n "$pd" ]]; then
                        printf '  Domain:  %s\n' "$pd"
                        printf '  HTTP:    http://%s\n' "$pd"
                        local ssl
                        ssl="$(site_get "mwp-panel" SSL_ENABLED 2>/dev/null || true)"
                        [[ "$ssl" == "yes" ]] && printf '  HTTPS:   https://%s\n' "$pd"
                    else
                        printf '  Not configured. Run: mwp panel setup\n'
                    fi
                    printf '\n'
                    ;;
                setup)
                    require_root
                    # Source install.sh — main() is guarded by BASH_SOURCE check, so safe.
                    # shellcheck source=/dev/null
                    source "$MWP_DIR/multi/install.sh"
                    step_panel_url_collect
                    step_panel_url_apply
                    ;;
                ssl)
                    require_root
                    local pd
                    pd="$(server_get "PANEL_DOMAIN")"
                    [[ -z "$pd" ]] && die "Panel domain not configured. Run: mwp panel setup"
                    _load_site_libs
                    ssl_issue "$pd"
                    ;;
                *) die "Usage: mwp panel [info|setup|ssl]" ;;
            esac
            ;;
        retune)
            _load_site_libs
            require_root
            if [[ "${1:-}" == "--dry-run" ]]; then
                tuning_report
            else
                tuning_retune_all
            fi
            ;;
        *)
            log_warn "Unknown command: $cmd"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
