#!/usr/bin/env bash
# lib/menu/security.sh — SSH hardening + Cloudflare protection + isolation audit
#
# Aggregates the three production-hardening surfaces that previously lived
# only in CLI flags:
#   ssh    : key-only login, fail2ban view
#   cf     : Cloudflare IP map, optional UFW lockdown
#   audit  : per-site isolation check (Linux user / open_basedir / DB scope / ...)

[[ -n "${_MWP_MENU_SECURITY_LOADED:-}" ]] && return 0
_MWP_MENU_SECURITY_LOADED=1

_menu_security_lazy_load() {
    [[ -n "${_MWP_SSH_LOADED:-}"        ]] || source "$MWP_DIR/lib/multi-ssh.sh"
    [[ -n "${_MWP_CF_LOADED:-}"         ]] || source "$MWP_DIR/lib/multi-cf.sh"
    [[ -n "${_MWP_ISOLATION_LOADED:-}"  ]] || source "$MWP_DIR/lib/multi-isolation.sh"
}

# ──────────────────────────────────────────────────────────────────────
# Level 1 — Security hub
# ──────────────────────────────────────────────────────────────────────

menu_security() {
    _menu_security_lazy_load

    # One-line state summary on the hub screen so the operator sees at a glance
    # what's on without having to click into each submenu.
    local _ssh_h _cf_r _bans
    _ssh_h="$(server_get SSH_HARDENED 2>/dev/null)"
    [[ -z "$_ssh_h" ]] && _ssh_h="no"
    _cf_r="$(server_get CF_RESTRICTED 2>/dev/null)"
    [[ -z "$_cf_r" ]] && _cf_r="no"
    if command -v fail2ban-client >/dev/null 2>&1; then
        _bans="$(fail2ban-client status sshd 2>/dev/null \
                 | awk -F: '/Currently banned/ {gsub(/^[ \t]+/,"",$2); print $2}')"
        [[ -z "$_bans" ]] && _bans=0
    else
        _bans="?"
    fi

    _mheader "Security"
    printf '\n'
    printf '  SSH harden:   %s   |   CF restrict: %s   |   fail2ban bans (sshd): %s\n' \
        "$_ssh_h" "$_cf_r" "$_bans"
    _mhr
    printf '\n'
    printf '  %b[1]%b  SSH hardening (status / harden / unharden)\n'   "$BOLD" "$NC"
    printf '  %b[2]%b  Cloudflare protection (status / refresh / lockdown)\n' "$BOLD" "$NC"
    printf '  %b[3]%b  Isolation audit (per-site or all-sites)\n'      "$BOLD" "$NC"
    printf '  %b[4]%b  fail2ban quick view (sshd jail)\n'              "$BOLD" "$NC"
    _mhr
    printf '  %b[0]%b  Back\n' "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1) _menu_ssh;       menu_security ;;
        2) _menu_cf;        menu_security ;;
        3) _menu_isolation; menu_security ;;
        4) _menu_f2b;       menu_security ;;
        0|b|back) menu_root ;;
        *) menu_security ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# SSH submenu
# ──────────────────────────────────────────────────────────────────────

_menu_ssh() {
    _menu_security_lazy_load
    _mc
    printf '\n  %bSSH hardening%b\n' "$BOLD" "$NC"
    _mhr
    ssh_status
    _mhr
    printf '  %b[1]%b  Harden  (disable password auth — needs ≥1 root key)\n' "$BOLD" "$NC"
    printf '  %b[2]%b  Unharden (restore distro defaults)\n' "$BOLD" "$NC"
    printf '  %b[3]%b  Refresh status\n' "$BOLD" "$NC"
    printf '  %b[0]%b  Back\n' "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1)
            require_root
            printf '\n  %bWarning: this will lock you out if your only auth is password!%b\n' "$RED" "$NC"
            printf '  Continue? (y/N): '
            local _c; read -r _c
            [[ "${_c,,}" == "y" ]] && ssh_harden || log_info "Cancelled."
            _mpause; _menu_ssh
            ;;
        2) require_root; ssh_unharden; _mpause; _menu_ssh ;;
        3) _menu_ssh ;;
        0|b|back) return ;;
        *) _menu_ssh ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Cloudflare submenu
# ──────────────────────────────────────────────────────────────────────

_menu_cf() {
    _menu_security_lazy_load
    _mc
    printf '\n  %bCloudflare protection%b\n' "$BOLD" "$NC"
    _mhr
    cf_status
    _mhr
    printf '  Per-domain CF guard runs automatically at site/app create.\n'
    printf '  Global UFW lockdown (below) is OPTIONAL — only enable if EVERY\n'
    printf '  site/app on this server is CF-proxied.\n'
    _mhr
    printf '  %b[1]%b  Refresh CF IP cache (re-fetch from cloudflare.com)\n'  "$BOLD" "$NC"
    printf '  %b[2]%b  Enable global UFW lockdown (CF-only on :80/:443)\n'    "$BOLD" "$NC"
    printf '  %b[3]%b  Disable global UFW lockdown\n'                          "$BOLD" "$NC"
    printf '  %b[4]%b  Refresh status\n'                                      "$BOLD" "$NC"
    printf '  %b[0]%b  Back\n' "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1) require_root; cf_refresh;       _mpause; _menu_cf ;;
        2)
            require_root
            printf '\n  %bThis will refuse if any site is NOT CF-proxied.%b\n' "$YELLOW" "$NC"
            printf '  Continue? (y/N): '
            local _c; read -r _c
            [[ "${_c,,}" == "y" ]] && cf_restrict_on || log_info "Cancelled."
            _mpause; _menu_cf
            ;;
        3) require_root; cf_restrict_off;  _mpause; _menu_cf ;;
        4) _menu_cf ;;
        0|b|back) return ;;
        *) _menu_cf ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Isolation audit submenu
# ──────────────────────────────────────────────────────────────────────

_menu_isolation() {
    _menu_security_lazy_load
    _load_site_libs    # for site_get, MENU_ENTITIES, _entities_table
    _mc
    printf '\n  %bIsolation audit%b\n' "$BOLD" "$NC"
    _mhr
    printf '  %b[1]%b  Audit ALL sites (one summary per site)\n' "$BOLD" "$NC"
    printf '  %b[2]%b  Audit single site (pick from list)\n'      "$BOLD" "$NC"
    printf '  %b[0]%b  Back\n' "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1)
            _mc
            local conf d
            for conf in "$MWP_SITES_DIR"/*.conf; do
                [[ -f "$conf" ]] || continue
                d="$(grep "^DOMAIN=" "$conf" | cut -d= -f2-)"
                printf '\n%b═══ %s ═══%b\n' "$BOLD" "$d" "$NC"
                isolation_check "$d" || true
            done
            _mpause; _menu_isolation
            ;;
        2)
            _mc
            _entities_table
            printf '  %b[0]%b  Cancel\n' "$BOLD" "$NC"
            _mprompt "Pick site #"
            if [[ "$MENU_INPUT" =~ ^[0-9]+$ ]] && \
               [[ $MENU_INPUT -ge 1 && $MENU_INPUT -le ${#MENU_ENTITIES[@]} ]]; then
                local sel="${MENU_ENTITIES[$((MENU_INPUT-1))]}"
                local kind="${sel%%:*}" id="${sel#*:}"
                if [[ "$kind" == "wp" ]]; then
                    _mc; isolation_check "$id" || true; _mpause
                else
                    log_warn "Isolation audit only applies to WordPress sites (not Docker apps / external)."
                    _mpause
                fi
            fi
            _menu_isolation
            ;;
        0|b|back) return ;;
        *) _menu_isolation ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# fail2ban quick view
# ──────────────────────────────────────────────────────────────────────

_menu_f2b() {
    _mc
    printf '\n  %bfail2ban — sshd jail%b\n' "$BOLD" "$NC"
    _mhr
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        printf '  fail2ban-client not installed.\n'
        _mpause; return
    fi
    fail2ban-client status sshd 2>/dev/null || log_warn "sshd jail not active"
    _mhr
    printf '  %b[1]%b  Show all active jails\n' "$BOLD" "$NC"
    printf '  %b[2]%b  Unban an IP\n'           "$BOLD" "$NC"
    printf '  %b[0]%b  Back\n' "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1)
            _mc; fail2ban-client status 2>/dev/null; _mpause; _menu_f2b
            ;;
        2)
            printf '  IP to unban: '
            local _ip; read -r _ip
            if [[ -n "$_ip" ]]; then
                require_root
                fail2ban-client set sshd unbanip "$_ip" 2>&1 || true
                _mpause
            fi
            _menu_f2b
            ;;
        0|b|back) return ;;
        *) _menu_f2b ;;
    esac
}
