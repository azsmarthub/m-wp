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
    printf '  %b[1]%b  Backup all sites (full)\n'      "$BOLD" "$NC"
    printf '  %b[2]%b  Backup a specific site\n'       "$BOLD" "$NC"
    printf '  %b[3]%b  Restore a site from backup\n'   "$BOLD" "$NC"
    _mhr
    printf '  %b[v]%b  Verify backup coverage          %b(what is backed up, age, offsite ✔/✗)%b\n' \
        "$BOLD" "$NC" "$DIM" "$NC"
    printf '  %b[b]%b  Browse all backup files         %b(restore / delete / push from one view)%b\n' \
        "$BOLD" "$NC" "$DIM" "$NC"
    _mhr
    printf '  %b[4]%b  Offsite backup (rclone)         %b— setup / status / list / pull%b\n' \
        "$BOLD" "$NC" "$DIM" "$NC"
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
        v|verify)
            _mc; backup_verify; _mpause; menu_backup
            ;;
        b|browse)
            _menu_backup_browse; menu_backup
            ;;
        0|back) menu_root ;;
        *) menu_backup ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Browse all backup files in 1 sortable view
# ──────────────────────────────────────────────────────────────────────

# Globals shared with the action sub-prompt
MENU_BACKUP_FILES=()
MENU_BACKUP_DOMAINS=()

_menu_backup_browse() {
    _mc
    printf '\n  %bAll backup files (newest first)%b\n' "$BOLD" "$NC"
    _mhr

    MENU_BACKUP_FILES=()
    MENU_BACKUP_DOMAINS=()

    # Collect (mtime|file|domain) tuples across all sites, then sort by mtime desc.
    local conf user domain bf mtime entry
    local -a tuples=()
    for conf in "$MWP_SITES_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        user="$(grep '^SITE_USER=' "$conf" | cut -d= -f2-)"
        domain="$(grep '^DOMAIN=' "$conf" | cut -d= -f2-)"
        for bf in /home/"$user"/backups/*.tar.gz /home/"$user"/backups/*.sql.gz; do
            [[ -f "$bf" ]] || continue
            mtime="$(stat -c %Y "$bf" 2>/dev/null || echo 0)"
            tuples+=("${mtime}|${bf}|${domain}")
        done
    done

    if [[ ${#tuples[@]} -eq 0 ]]; then
        printf '  (no backup files found on disk)\n'
        _mhr
        printf '  %b[0]%b Back\n' "$BOLD" "$NC"
        _mprompt
        return
    fi

    # Sort newest first
    local -a sorted=()
    while IFS= read -r entry; do
        sorted+=("$entry")
    done < <(printf '%s\n' "${tuples[@]}" | sort -rn)

    printf '  %b%-3s  %-46s  %-22s  %-16s  %s%b\n' \
        "$BOLD" "#" "FILE" "SITE" "DATE" "SIZE" "$NC"
    _mhr

    local idx=0 file fname date_str size
    for entry in "${sorted[@]}"; do
        mtime="${entry%%|*}"
        file="${entry#*|}"; file="${file%|*}"
        domain="${entry##*|}"
        fname="$(basename "$file")"
        date_str="$(date -d "@${mtime}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
        size="$(du -h "$file" 2>/dev/null | cut -f1)"

        idx=$(( idx + 1 ))
        MENU_BACKUP_FILES+=("$file")
        MENU_BACKUP_DOMAINS+=("$domain")
        # Truncate long filenames to fit
        local fname_short="$fname"
        [[ ${#fname_short} -gt 46 ]] && fname_short="${fname_short:0:43}..."
        printf '  %b%-3s%b  %-46s  %-22s  %-16s  %s\n' \
            "$BOLD" "$idx" "$NC" "$fname_short" "$domain" "$date_str" "$size"
    done

    _mhr
    printf '  Action format: %b<letter><#>%b — e.g. %br3%b restore #3, %bd5%b delete #5, %bp1%b push #1\n' \
        "$BOLD" "$NC" "$BOLD" "$NC" "$BOLD" "$NC" "$BOLD" "$NC"
    printf '  %b[r#]%b Restore   %b[d#]%b Delete   %b[p#]%b Push to remote   %b[0]%b Back\n' \
        "$BOLD" "$NC" "$BOLD" "$NC" "$BOLD" "$NC" "$BOLD" "$NC"
    _mprompt "Action"

    case "$MENU_INPUT" in
        0|back) return ;;
        r*) _backup_browse_act "restore" "${MENU_INPUT#r}" ;;
        d*) _backup_browse_act "delete"  "${MENU_INPUT#d}" ;;
        p*) _backup_browse_act "push"    "${MENU_INPUT#p}" ;;
        *)  _menu_backup_browse ;;
    esac
}

# Apply an action (restore/delete/push) to a numbered backup from the
# browse table. Re-renders the browse view after.
_backup_browse_act() {
    local action="$1" num="$2"
    if ! [[ "$num" =~ ^[0-9]+$ ]] || \
       [[ $num -lt 1 || $num -gt ${#MENU_BACKUP_FILES[@]} ]]; then
        log_warn "Invalid number: '$num'"
        _mpause; _menu_backup_browse; return
    fi
    local file="${MENU_BACKUP_FILES[$((num-1))]}"
    local domain="${MENU_BACKUP_DOMAINS[$((num-1))]}"

    case "$action" in
        restore)
            require_root
            printf '\n  %bRestore %s%b → site %b%s%b\n' "$BOLD" "$(basename "$file")" "$NC" "$BOLD" "$domain" "$NC"
            printf '  This OVERWRITES current files + database for %s. Continue? (y/N): ' "$domain"
            local _c; read -r _c
            [[ "${_c,,}" == "y" ]] && restore_site "$domain" "$file" || log_info "Cancelled."
            _mpause
            ;;
        delete)
            require_root
            printf '\n  %bDelete %s%b\n' "$BOLD" "$(basename "$file")" "$NC"
            printf '  Local file will be removed (offsite copy untouched). Continue? (y/N): '
            local _c; read -r _c
            if [[ "${_c,,}" == "y" ]]; then
                rm -f "$file" && log_success "Deleted: $file"
            else
                log_info "Cancelled."
            fi
            _mpause
            ;;
        push)
            require_root
            [[ -n "${_MWP_BACKUP_REMOTE_LOADED:-}" ]] || \
                source "$MWP_DIR/lib/multi-backup-remote.sh"
            local target
            target="$(server_get BACKUP_REMOTE 2>/dev/null || true)"
            if [[ -z "$target" ]]; then
                log_warn "No offsite remote configured. Run: mwp backup gdrive setup"
                _mpause
            else
                backup_remote_push "$file" || true
                _mpause
            fi
            ;;
    esac
    _menu_backup_browse
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
    printf '  %b[g]%b  Google Drive quick setup  %b(OAuth or Service Account — recommended)%b\n' \
        "$BOLD" "$NC" "$DIM" "$NC"
    _mhr
    printf '  %b[1]%b  Install rclone (idempotent)\n'                 "$BOLD" "$NC"
    printf '  %b[2]%b  Configure remote (full rclone wizard — S3/B2/SFTP/etc.)\n' "$BOLD" "$NC"
    printf '  %b[3]%b  Set active offsite target (<remote>:<path>)\n'  "$BOLD" "$NC"
    printf '  %b[4]%b  Disable offsite uploads (unset)\n'              "$BOLD" "$NC"
    printf '  %b[5]%b  List remote backups\n'                          "$BOLD" "$NC"
    printf '  %b[6]%b  Pull a remote archive into /tmp\n'              "$BOLD" "$NC"
    printf '  %b[7]%b  Push a local backup file to remote\n'           "$BOLD" "$NC"
    printf '  %b[8]%b  Refresh status\n'                               "$BOLD" "$NC"
    printf '  %b[0]%b  Back\n' "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        g|gdrive)
            require_root
            [[ -n "${_MWP_BACKUP_GDRIVE_LOADED:-}" ]] || \
                source "$MWP_DIR/lib/multi-backup-gdrive.sh"
            backup_gdrive_setup
            _mpause; _menu_backup_remote
            ;;
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
