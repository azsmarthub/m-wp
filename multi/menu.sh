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

# Load Docker-app libs lazily (Phase 5: Docker apps)
_load_app_libs() {
    source "$MWP_DIR/lib/multi-docker.sh"
    source "$MWP_DIR/lib/app-registry.sh"
    source "$MWP_DIR/lib/multi-nginx.sh"
    source "$MWP_DIR/lib/multi-app.sh"
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
  mwp site login   <domain> [uid]  Magic-link auto-login (24h, single-use, default uid=1)

${BOLD}PHP:${NC}
  mwp php list                     List installed PHP versions
  mwp php install <version>        Install PHP version (8.1/8.2/8.3/8.4/8.5)
  mwp php switch  <domain> <ver>   Switch site PHP version

${BOLD}Cache:${NC}
  mwp cache purge  <domain>        Purge FastCGI + Redis cache for site
  mwp cache purge-all              Purge all sites

${BOLD}SSL:${NC}
  mwp ssl issue  <domain>          Issue cert (auto: LE direct, self-signed CF)
  mwp ssl renew                    Renew all certificates
  mwp ssl status <domain>          Show SSL expiry
  mwp ssl verify-cf <domain>       Verify CF→origin reachability (catches 526)
  mwp ssl install-origin-cert <domain> [cert.pem key.pem]
                                   Install CF Origin Cert (Full Strict mode)

${BOLD}SSH hardening:${NC}
  mwp ssh status                   Show auth modes + key count + ban stats
  mwp ssh harden                   Disable password auth (key-only) — needs ≥1 root key
  mwp ssh unharden                 Revert to distro default (password+key)

${BOLD}Cloudflare protection (always-on per-domain auto):${NC}
  mwp cf status                    Show CF map + per-site CF_PROXIED states
  mwp cf refresh                   Re-fetch CF ranges + regenerate nginx map
                                   (installed at server setup; cron weekly)
  mwp cf restrict-on               (Optional) global UFW lockdown — all sites must be CF
  mwp cf restrict-off              Disable UFW lockdown

${BOLD}Backup:${NC}
  mwp backup full <domain>         Full backup (files + DB)
  mwp backup db   <domain>         Database-only backup
  mwp backup all                   Backup all sites
  mwp restore     <domain> <file>  Restore from backup
  mwp backup remote setup          Configure offsite (rclone wizard: B2/S3/GDrive/SFTP)
  mwp backup remote set <r:path>   Mark <remote>:<path> as active offsite target
  mwp backup remote status         Show config + last upload + remote disk usage
  mwp backup remote list [domain]  List remote archives
  mwp backup remote pull <name>    Download a remote archive into /tmp
  mwp backup gdrive setup          Google Drive quick setup (OAuth or Service Account)
  mwp backup verify                Coverage report — list each entity + backup age + offsite
  mwp backup schedule list         List schedule presets (daily / every-2-days / weekly...)
  mwp backup schedule set <preset> Install systemd timer (default: every-2-days)
  mwp backup schedule status       Show current schedule + next run + last result
  mwp backup schedule run          Run a scheduled backup right now
  mwp backup schedule disable      Stop + remove the timer
  mwp backup retention show        Show keep-counts per tier
  mwp backup retention set daily=14 weekly=8 monthly=24
                                   Configure per-tier retention

${BOLD}Docker apps (Next.js, n8n, Node repos, …):${NC}
  mwp docker install               Install Docker engine + nginx WS support
  mwp docker status                Show Docker engine status
  mwp app list                     List all apps
  mwp app create <name> --domain D --image IMG [--port P] [--memory M]
                                   [--env K=V]... [--env-file F] [--volume H:C]...
  mwp app info     <name>          Show app config + container state
  mwp app start    <name>          Start container
  mwp app stop     <name>          Stop container
  mwp app restart  <name>          Restart container
  mwp app logs     <name> [-f]     Follow container logs
  mwp app exec     <name> -- <cmd> Run a command inside the container
  mwp app shell    <name>          Open a shell inside the container
  mwp app delete   <name>          Delete app (container + vhost + data)
  mwp app register <container>     Register an EXISTING Docker container for backup
  mwp app backup   <name> [tier]   Backup app data + config (tier: full|daily|weekly|monthly)
  mwp app restore  <name> <file>   Restore app from a backup archive

${BOLD}Server:${NC}
  mwp status                       Server + all sites overview
  mwp status <domain>              Single site status
  mwp retune                       Recalculate + apply FPM pools for all sites
  mwp retune --dry-run             Show what retune would change
  mwp panel info                   Show panel URL info
  mwp panel setup                  Configure panel hostname (sv1.yourdomain.com)
  mwp panel ssl                    Issue SSL for panel domain

${BOLD}Self-update:${NC}
  mwp version                      Show local version
  mwp version --remote             Show local + latest release on GitHub
  mwp update                       Update to latest release tag (stable channel)
  mwp update --main                Update to bleeding-edge origin/main
  mwp update --tag v0.5.1          Pin to a specific tag
  mwp update --check               Dry-run — list pending commits
  mwp update --force               Discard local modifications + update

${BOLD}Examples:${NC}
  mwp site create example.com
  mwp php switch example.com 8.2
  mwp cache purge example.com
  mwp backup full example.com
  mwp docker install
  mwp app create n8n --domain n8n.example.com --image docker.n8n.io/n8nio/n8n --port 5678
  mwp app create blog --domain blog.example.com --image ghost:5 --port 2368
  mwp app create api  --domain api.example.com  --image ghcr.io/me/api:latest --port 8080

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
        create|delete|info|enable|disable|shell|check-isolation|login) ;;
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
        # Pass "$@" not "${1:-}" — site_create accepts flags like --allow-non-cf
        # after the domain. Same for delete (in case future flags).
        create)  require_root; site_create "$@" ;;
        delete)  require_root; site_delete "$@" ;;
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
        login)
            # Magic-link auto-login (mu-plugin pattern). 24h TTL, single-use.
            site_magic_login "${1:-}" "${2:-1}"
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
        status) ssl_status "${1:-}" ;;
        install-origin-cert|install-cf-cert)
            require_root
            ssl_install_origin_cert "${1:-}" "${2:-}" "${3:-}"
            ;;
        verify-cf)
            require_root
            local d="${1:-}"
            [[ -z "$d" ]] && die "Usage: mwp ssl verify-cf <domain>"
            _ssl_verify_cf_accepts_origin "$d" "/etc/mwp/ssl/${d}"
            ;;
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
        remote)
            local rsub="${1:-status}"
            shift || true
            source "$MWP_DIR/lib/multi-backup-remote.sh"
            case "$rsub" in
                install) backup_remote_install ;;
                setup)   backup_remote_setup ;;
                set)     backup_remote_set "${1:-}" ;;
                unset)   backup_remote_unset ;;
                status)  backup_remote_status ;;
                push)    backup_remote_push "${1:-}" ;;
                list|ls) backup_remote_list "${1:-}" ;;
                pull)    backup_remote_pull "${1:-}" ;;
                *) cmd_help; die "Unknown backup remote subcommand: $rsub" ;;
            esac
            ;;
        gdrive)
            # Focused Google Drive setup — bypasses the full rclone wizard.
            local gsub="${1:-setup}"
            shift || true
            source "$MWP_DIR/lib/multi-backup-gdrive.sh"
            case "$gsub" in
                setup) backup_gdrive_setup ;;
                *) cmd_help; die "Usage: mwp backup gdrive setup" ;;
            esac
            ;;
        verify)
            # Coverage report — what's backed up, what's stale, what's missing.
            backup_verify
            ;;
        schedule)
            # Scheduled backups via systemd timer. Subcommands:
            #   list / set <preset> [custom-spec] / disable / status / run
            #   run-internal     — entry point used by mwp-backup.service unit
            local ssub="${1:-status}"
            shift || true
            source "$MWP_DIR/lib/multi-backup-schedule.sh"
            case "$ssub" in
                list|presets) backup_schedule_list_presets ;;
                set)          backup_schedule_set "${1:-}" "${2:-}" ;;
                disable|off)  backup_schedule_disable ;;
                status|info)  backup_schedule_status ;;
                run|run-now)  backup_schedule_run_now ;;
                run-internal)
                    # Called by the systemd unit. Not for interactive use.
                    backup_all_scheduled
                    ;;
                *) cmd_help; die "Usage: mwp backup schedule {list|set <preset>|disable|status|run}" ;;
            esac
            ;;
        retention)
            # Configure how many backups to keep per tier.
            #   show              — print current keep-counts
            #   set <key>=<val>...— e.g. mwp backup retention set daily=14 weekly=8
            local rsub="${1:-show}"
            shift || true
            case "$rsub" in
                show)
                    printf '\n  %bBackup retention (per-site, per-tier)%b\n' "$BOLD" "$NC"
                    printf '  %s\n' "──────────────────────────────────────"
                    local kd kw km kf
                    kd="$(server_get BACKUP_KEEP_DAILY 2>/dev/null   || true)"; kd="${kd:-7}"
                    kw="$(server_get BACKUP_KEEP_WEEKLY 2>/dev/null  || true)"; kw="${kw:-4}"
                    km="$(server_get BACKUP_KEEP_MONTHLY 2>/dev/null || true)"; km="${km:-12}"
                    kf="$(server_get BACKUP_KEEP_FULL 2>/dev/null    || true)"; kf="${kf:-7}"
                    printf '  daily=%s   weekly=%s   monthly=%s   full(manual)=%s\n\n' \
                        "$kd" "$kw" "$km" "$kf"
                    ;;
                set)
                    require_root
                    [[ $# -eq 0 ]] && die "Usage: mwp backup retention set daily=N [weekly=N] [monthly=N] [full=N]"
                    local pair k v key
                    for pair in "$@"; do
                        k="${pair%%=*}"; v="${pair#*=}"
                        [[ "$v" =~ ^[0-9]+$ ]] || die "Bad value: $pair (expected key=N)"
                        case "$k" in
                            daily)   key=BACKUP_KEEP_DAILY ;;
                            weekly)  key=BACKUP_KEEP_WEEKLY ;;
                            monthly) key=BACKUP_KEEP_MONTHLY ;;
                            full)    key=BACKUP_KEEP_FULL ;;
                            *) die "Unknown retention key: $k (use daily|weekly|monthly|full)" ;;
                        esac
                        server_set "$key" "$v"
                        log_success "$key = $v"
                    done
                    ;;
                *) die "Usage: mwp backup retention {show|set <key>=N ...}" ;;
            esac
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
# Docker engine commands
# ---------------------------------------------------------------------------
cmd_docker() {
    local sub="${1:-status}"
    shift || true
    _load_app_libs

    case "$sub" in
        install) docker_engine_install ;;
        status)  docker_engine_status ;;
        *) cmd_help; die "Unknown docker subcommand: $sub" ;;
    esac
}

# ---------------------------------------------------------------------------
# App (Docker container) commands
# ---------------------------------------------------------------------------
cmd_app() {
    local sub="${1:-list}"
    shift || true
    _load_app_libs

    case "$sub" in
        create)  app_create "$@" ;;
        delete|rm) app_delete "${1:-}" ;;
        list|ls) app_registry_print_list ;;
        info)    app_registry_print_info "${1:-}" ;;
        start)   app_start "${1:-}" ;;
        stop)    app_stop  "${1:-}" ;;
        restart) app_restart "${1:-}" ;;
        logs)
            local name="${1:-}"; shift || true
            app_logs "$name" "$@"
            ;;
        exec)
            local name="${1:-}"; shift || true
            app_exec "$name" "$@"
            ;;
        shell)   app_shell "${1:-}" ;;
        register)
            # Register an existing (external) Docker container so backup +
            # scheduled runs can include it.
            source "$MWP_DIR/lib/multi-app-backup.sh"
            app_register "${1:-}"
            ;;
        backup)
            # mwp app backup <name> [tier]
            source "$MWP_DIR/lib/multi-app-backup.sh"
            backup_app "${1:-}" "${2:-full}"
            ;;
        restore)
            # mwp app restore <name> <archive>
            source "$MWP_DIR/lib/multi-app-backup.sh"
            restore_app "${1:-}" "${2:-}"
            ;;
        *) cmd_help; die "Unknown app subcommand: $sub" ;;
    esac
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
        version|--version|-v)
            # `mwp version` — local only (offline-safe, no network call)
            # `mwp version --remote` — also queries GitHub for latest release
            if [[ "${1:-}" == "--remote" || "${1:-}" == "-r" ]]; then
                source "$MWP_DIR/lib/multi-update.sh"
                update_status
            else
                printf 'mwp v%s\n' "$MWP_VERSION"
            fi
            ;;
        update)
            # mwp update                   → latest release tag (stable)
            # mwp update --main            → bleeding-edge origin/main
            # mwp update --tag v0.5.1      → pin to a specific tag
            # mwp update --check           → dry-run (list pending commits)
            # mwp update --force           → discard local modifications
            # mwp update status            → same as `mwp version --remote`
            source "$MWP_DIR/lib/multi-update.sh"
            case "${1:-}" in
                status|info)               update_status ;;
                check)                     shift; update_check "$@" ;;
                ""|--main|--tag|--force|--check) update_apply "$@" ;;
                *) die "Usage: mwp update [status|check] [--main|--tag <tag>|--check|--force]" ;;
            esac
            ;;
        status)  cmd_status "$@" ;;
        sites)
            _load_site_libs; _load_menu_lib; menu_sites "${1:-}"
            ;;
        site)    cmd_site "$@" ;;
        apps)
            # `mwp apps` (no subcommand) → interactive Apps menu.
            # Subcommands (create/list/info/...) still go through cmd_app.
            if [[ $# -eq 0 ]]; then
                _load_site_libs; _load_app_libs; _load_menu_lib; menu_apps
            else
                cmd_app "$@"
            fi
            ;;
        security|sec)
            _load_site_libs; _load_menu_lib; menu_security
            ;;
        php)     cmd_php "$@" ;;
        cache)   cmd_cache "$@" ;;
        ssl)     cmd_ssl "$@" ;;
        backup)  cmd_backup "$@" ;;
        restore) cmd_restore "$@" ;;
        docker)  cmd_docker "$@" ;;
        app)
            # `mwp app` (no subcommand) → interactive Apps menu.
            # Subcommands (create/list/info/...) → cmd_app.
            if [[ $# -eq 0 ]]; then
                _load_site_libs; _load_app_libs; _load_menu_lib; menu_apps
            else
                cmd_app "$@"
            fi
            ;;
        ssh)
            local sub="${1:-status}"
            shift || true
            source "$MWP_DIR/lib/multi-ssh.sh"
            case "$sub" in
                status)    ssh_status ;;
                harden)    ssh_harden ;;
                unharden)  ssh_unharden ;;
                *) cmd_help; die "Unknown ssh subcommand: $sub" ;;
            esac
            ;;
        cf)
            local sub="${1:-status}"
            shift || true
            source "$MWP_DIR/lib/multi-cf.sh"
            case "$sub" in
                status)        cf_status ;;
                restrict-on|restrict|on)   cf_restrict_on ;;
                restrict-off|unrestrict|off) cf_restrict_off ;;
                refresh)       cf_refresh ;;
                *) cmd_help; die "Unknown cf subcommand: $sub" ;;
            esac
            ;;
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
