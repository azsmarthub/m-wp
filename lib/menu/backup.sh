#!/usr/bin/env bash
# lib/menu/backup.sh — Backups & Restore (local + offsite via rclone)

[[ -n "${_MWP_MENU_BACKUP_LOADED:-}" ]] && return 0
_MWP_MENU_BACKUP_LOADED=1

_menu_backup_remote_lazy_load() {
    [[ -n "${_MWP_BACKUP_REMOTE_LOADED:-}" ]] || \
        source "$MWP_DIR/lib/multi-backup-remote.sh"
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
    printf '  %b[4]%b  Offsite backup (rclone) — setup / status / list / pull\n' "$BOLD" "$NC"
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
            _entities_table
            printf '  %b[0]%b  Cancel\n' "$BOLD" "$NC"
            _mprompt "Pick site #"
            if [[ "$MENU_INPUT" =~ ^[0-9]+$ ]] && \
               [[ $MENU_INPUT -ge 1 && $MENU_INPUT -le ${#MENU_ENTITIES[@]} ]]; then
                local sel="${MENU_ENTITIES[$((MENU_INPUT-1))]}"
                local kind="${sel%%:*}" id="${sel#*:}"
                if [[ "$kind" == "wp" ]]; then
                    _menu_do_backup "$id"
                else
                    log_warn "Backup currently only supports WordPress sites."
                    _mpause
                fi
            fi
            menu_backup
            ;;
        3)
            _entities_table
            printf '  %b[0]%b  Cancel\n' "$BOLD" "$NC"
            _mprompt "Pick site #"
            if [[ "$MENU_INPUT" =~ ^[0-9]+$ ]] && \
               [[ $MENU_INPUT -ge 1 && $MENU_INPUT -le ${#MENU_ENTITIES[@]} ]]; then
                local sel="${MENU_ENTITIES[$((MENU_INPUT-1))]}"
                local kind="${sel%%:*}" id="${sel#*:}"
                if [[ "$kind" == "wp" ]]; then
                    _menu_do_restore "$id"
                else
                    log_warn "Restore currently only supports WordPress sites."
                    _mpause
                fi
            fi
            menu_backup
            ;;
        4) _menu_backup_remote; menu_backup ;;
        0|b|back) menu_root ;;
        *) menu_backup ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Offsite backup submenu (rclone)
# ──────────────────────────────────────────────────────────────────────

_menu_backup_remote() {
    _menu_backup_remote_lazy_load
    _mc
    printf '\n  %bOffsite backup (rclone)%b\n' "$BOLD" "$NC"
    _mhr
    backup_remote_status
    _mhr
    printf '  %b[1]%b  Install rclone (idempotent)\n'                 "$BOLD" "$NC"
    printf '  %b[2]%b  Configure remote (interactive rclone wizard)\n' "$BOLD" "$NC"
    printf '  %b[3]%b  Set active offsite target (<remote>:<path>)\n'  "$BOLD" "$NC"
    printf '  %b[4]%b  Disable offsite uploads (unset)\n'              "$BOLD" "$NC"
    printf '  %b[5]%b  List remote backups\n'                          "$BOLD" "$NC"
    printf '  %b[6]%b  Pull a remote archive into /tmp\n'              "$BOLD" "$NC"
    printf '  %b[7]%b  Push a local backup file to remote\n'           "$BOLD" "$NC"
    printf '  %b[8]%b  Refresh status\n'                               "$BOLD" "$NC"
    printf '  %b[0]%b  Back\n' "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1) require_root; backup_remote_install; _mpause; _menu_backup_remote ;;
        2) require_root; backup_remote_setup;   _mpause; _menu_backup_remote ;;
        3)
            printf '  Target (e.g. b2-backup:mwp-vps01-backups): '
            local _t; read -r _t
            [[ -n "$_t" ]] && { require_root; backup_remote_set "$_t"; _mpause; }
            _menu_backup_remote
            ;;
        4) require_root; backup_remote_unset;   _mpause; _menu_backup_remote ;;
        5)
            printf '  Filter by domain (ENTER for none): '
            local _f; read -r _f
            backup_remote_list "$_f"; _mpause; _menu_backup_remote
            ;;
        6)
            printf '  Archive name (from list): '
            local _a; read -r _a
            [[ -n "$_a" ]] && { require_root; backup_remote_pull "$_a"; _mpause; }
            _menu_backup_remote
            ;;
        7)
            printf '  Local file path: '
            local _f; read -r _f
            [[ -n "$_f" ]] && { require_root; backup_remote_push "$_f"; _mpause; }
            _menu_backup_remote
            ;;
        8) _menu_backup_remote ;;
        0|b|back) return ;;
        *) _menu_backup_remote ;;
    esac
}
