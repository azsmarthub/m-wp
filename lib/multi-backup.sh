#!/usr/bin/env bash
# lib/multi-backup.sh — Per-site backup/restore for mwp

[[ -n "${_MWP_BACKUP_LOADED:-}" ]] && return 0
_MWP_BACKUP_LOADED=1

# ---------------------------------------------------------------------------
# backup_site <domain> <type: full|db|files>
# Output: /home/<user>/backups/<domain>-<type>-<date>.tar.gz
# ---------------------------------------------------------------------------
backup_site() {
    local domain="${1:-}" type="${2:-full}"
    [[ -z "$domain" ]] && die "Usage: mwp backup <full|db|files> <domain>"
    site_exists "$domain" || die "Site '$domain' not found."

    local site_user web_root db_name db_user db_pass backup_dir timestamp archive
    site_user="$(site_get "$domain" SITE_USER)"
    web_root="$(site_get "$domain" WEB_ROOT)"
    db_name="$(site_get "$domain" DB_NAME)"
    db_user="$(site_get "$domain" DB_USER)"
    db_pass="$(site_get "$domain" DB_PASS)"
    backup_dir="/home/${site_user}/backups"
    timestamp="$(date '+%Y%m%d-%H%M%S')"

    mkdir -p "$backup_dir"

    log_info "Backing up ${domain} (${type})..."

    case "$type" in
        full)
            archive="${backup_dir}/${domain}-full-${timestamp}.tar.gz"

            # 1. Dump DB
            local db_dump="/tmp/mwp-db-${domain}-${timestamp}.sql"
            log_sub "Dumping database..."
            mysqldump --single-transaction --quick --skip-lock-tables \
                -u "$db_user" -p"$db_pass" "$db_name" > "$db_dump" 2>/dev/null || \
                die "mysqldump failed for $db_name"

            # 2. Archive files + db dump
            log_sub "Archiving files..."
            tar czf "$archive" \
                -C "$(dirname "$web_root")" "$(basename "$web_root")" \
                -C /tmp "$(basename "$db_dump")" \
                2>/dev/null || die "tar archive failed"

            rm -f "$db_dump"
            ;;

        db)
            archive="${backup_dir}/${domain}-db-${timestamp}.sql.gz"
            log_sub "Dumping database..."
            mysqldump --single-transaction --quick --skip-lock-tables \
                -u "$db_user" -p"$db_pass" "$db_name" 2>/dev/null | \
                gzip > "$archive" || die "Database dump failed"
            ;;

        files)
            archive="${backup_dir}/${domain}-files-${timestamp}.tar.gz"
            log_sub "Archiving files (no DB)..."
            tar czf "$archive" \
                -C "$(dirname "$web_root")" "$(basename "$web_root")" \
                2>/dev/null || die "tar archive failed"
            ;;

        *) die "Unknown backup type: $type. Use: full | db | files" ;;
    esac

    chown "${site_user}:${site_user}" "$archive"
    local size
    size="$(du -sh "$archive" 2>/dev/null | cut -f1)"
    log_success "Backup saved: $archive (${size})"

    # Keep only last 7 full backups per site
    _backup_rotate "$backup_dir" "$domain" "full" 7
    _backup_rotate "$backup_dir" "$domain" "db" 14

    # Auto-push to offsite if configured. Failure does NOT fail the local
    # backup — local copy is already saved; offsite is best-effort. Operator
    # sees the warning and can retry: `mwp backup remote push <archive>`.
    if [[ -n "$(server_get "BACKUP_REMOTE" 2>/dev/null)" ]]; then
        if [[ -f "$MWP_DIR/lib/multi-backup-remote.sh" ]]; then
            # shellcheck source=/dev/null
            source "$MWP_DIR/lib/multi-backup-remote.sh"
            backup_remote_push "$archive" || \
                log_warn "Offsite push failed for $archive — local copy intact."
        fi
    fi
}

# ---------------------------------------------------------------------------
# rotate old backups (keep N most recent)
# ---------------------------------------------------------------------------
_backup_rotate() {
    local dir="$1" domain="$2" type="$3" keep="$4"
    local files
    # `ls` returns non-zero when the glob doesn't match (e.g. first-ever
    # `mwp backup full` rotates BOTH "full" and "db" types but only the
    # "full" file exists). Under the script-wide `set -o pipefail`, that
    # propagates out of $(...) and `set -e` aborts backup_site BEFORE we
    # get to the offsite-push step — silently breaking auto-upload to
    # Google Drive / S3 / etc. on the first run.
    #
    # Wrap in a subshell with pipefail off + `|| true` so a no-match is
    # treated as "nothing to rotate", not as a failure.
    # shellcheck disable=SC2012
    files="$( set +o pipefail
              ls -t "${dir}/${domain}-${type}-"* 2>/dev/null \
                  | tail -n +$(( keep + 1 )) )" || true
    if [[ -n "$files" ]]; then
        echo "$files" | xargs rm -f
        log_sub "Rotated old ${type} backups (kept ${keep})"
    fi
}

# ---------------------------------------------------------------------------
# restore_site <domain> <backup-file>
# ---------------------------------------------------------------------------
restore_site() {
    local domain="${1:-}" backup_file="${2:-}"
    [[ -z "$domain" || -z "$backup_file" ]] && die "Usage: mwp restore <domain> <backup-file>"
    site_exists "$domain" || die "Site '$domain' not found."
    [[ -f "$backup_file" ]] || die "Backup file not found: $backup_file"

    local site_user web_root db_name db_user db_pass
    site_user="$(site_get "$domain" SITE_USER)"
    web_root="$(site_get "$domain" WEB_ROOT)"
    db_name="$(site_get "$domain" DB_NAME)"
    db_user="$(site_get "$domain" DB_USER)"
    db_pass="$(site_get "$domain" DB_PASS)"

    printf '\n%bRestore site: %s%b\n' "$YELLOW" "$domain" "$NC"
    printf 'From: %s\n' "$backup_file"
    confirm "This will OVERWRITE current files and database. Continue?" || { log_info "Aborted."; return 0; }

    local tmp_dir="/tmp/mwp-restore-${domain}-$$"
    mkdir -p "$tmp_dir"
    # NOTE: don't use `trap ... EXIT` here — $tmp_dir is local to this function,
    # so by the time the script exits and the trap fires, the variable is unset
    # and `set -u` triggers "tmp_dir: unbound variable". Cleanup explicitly
    # at the end of each branch instead.

    case "$backup_file" in
        *.tar.gz)
            log_sub "Extracting archive..."
            tar xzf "$backup_file" -C "$tmp_dir" 2>/dev/null || die "Extraction failed"

            # Restore files
            local extracted_web
            extracted_web="$(find "$tmp_dir" -name "$(basename "$web_root")" -type d | head -1)"
            if [[ -n "$extracted_web" ]]; then
                log_sub "Restoring files to ${web_root}..."
                rsync -a --delete "${extracted_web}/" "${web_root}/"
                chown -R "${site_user}:${site_user}" "$web_root"
            fi

            # Restore DB (look for .sql file in archive)
            local sql_file
            sql_file="$(find "$tmp_dir" -name "*.sql" | head -1)"
            if [[ -n "$sql_file" ]]; then
                log_sub "Restoring database..."
                mysql -u "$db_user" -p"$db_pass" "$db_name" < "$sql_file" 2>/dev/null || \
                    die "Database restore failed"
            fi
            ;;

        *.sql.gz)
            log_sub "Restoring database from SQL dump..."
            gunzip -c "$backup_file" | mysql -u "$db_user" -p"$db_pass" "$db_name" 2>/dev/null || \
                die "Database restore failed"
            ;;

        *) die "Unsupported backup format: $backup_file (expected .tar.gz or .sql.gz)" ;;
    esac

    rm -rf "$tmp_dir"
    log_success "Restore complete for ${domain}"
}


# ---------------------------------------------------------------------------
# backup_verify — coverage report across WP sites + Docker apps
#
# For each entity, find the most recent local backup, compute age, check
# whether it also exists offsite (single rclone lsf call cached across
# all rows). Color-codes age: green <3d, yellow <7d, red >7d.
#
# Output is a table; safe to call from CLI or interactively.
# ---------------------------------------------------------------------------
backup_verify() {
    printf '\n%b  Backup coverage report%b  (%s)\n'         "$BOLD" "$NC" "$(date '+%Y-%m-%d %H:%M')"
    printf '  %s\n' "$(printf '─%.0s' {1..82})"
    printf '  %b%-3s  %-32s  %-10s  %-16s  %-6s  %-6s  %s%b\n' \
        "$BOLD" "#" "ENTITY" "TYPE" "LATEST BACKUP" "AGE" "SIZE" "OFFSITE" "$NC"
    printf '  %s\n' "$(printf '─%.0s' {1..82})"

    local target offsite_files=""
    target="$(server_get BACKUP_REMOTE 2>/dev/null || true)"

    # One rclone listing covers ALL rows. Cache as |-padded so a fast case-glob
    # match works per-row without forking rclone 30 times.
    if [[ -n "$target" ]]; then
        local hn
        hn="$(hostname -f 2>/dev/null || hostname)"
        offsite_files="|$( set +o pipefail
                          rclone lsf "$target/$hn/" 2>/dev/null \
                            | tr '\n' '|'
                        )" || true
    fi

    local idx=0 conf domain user bdir latest mtime now age_sec age_str date_str size fname offsite_col
    local now_epoch
    now_epoch="$(date +%s)"

    # 1) WordPress sites
    if [[ -d "$MWP_SITES_DIR" ]] && ls "$MWP_SITES_DIR"/*.conf &>/dev/null 2>&1; then
        for conf in "$MWP_SITES_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            idx=$(( idx + 1 ))
            domain="$(grep '^DOMAIN=' "$conf" | cut -d= -f2-)"
            user="$(grep '^SITE_USER=' "$conf" | cut -d= -f2-)"
            bdir="/home/${user}/backups"
            latest=""
            if compgen -G "${bdir}/${domain}-full-"*".tar.gz" >/dev/null 2>&1; then
                latest="$( set +o pipefail
                            ls -t "${bdir}/${domain}-full-"*".tar.gz" 2>/dev/null | head -1
                          )" || true
            fi
            if [[ -n "$latest" && -f "$latest" ]]; then
                mtime="$(stat -c %Y "$latest")"
                age_sec=$(( now_epoch - mtime ))
                age_str="$(_backup_human_age "$age_sec")"
                size="$(du -h "$latest" 2>/dev/null | cut -f1)"
                fname="$(basename "$latest")"
                date_str="$(date -d @"$mtime" '+%Y-%m-%d %H:%M')"

                offsite_col="—"
                if [[ -n "$target" ]]; then
                    case "$offsite_files" in
                        *"|$fname|"*) offsite_col="${GREEN}✔${NC} gdrive" ;;
                        *)              offsite_col="${RED}✗${NC}" ;;
                    esac
                fi

                local age_col
                if   (( age_sec > 7*86400 )); then age_col="${RED}${age_str}${NC}"
                elif (( age_sec > 3*86400 )); then age_col="${YELLOW}${age_str}${NC}"
                else                               age_col="${GREEN}${age_str}${NC}"
                fi
                printf '  %b%-3s%b  %-32s  %-10s  %-16s  %-6s  %-6s  %s\n' \
                    "$BOLD" "$idx" "$NC" "$domain" "WordPress" \
                    "$date_str" "$age_col" "$size" "$offsite_col"
            else
                printf '  %b%-3s%b  %-32s  %-10s  %b%-16s%b  %-6s  %-6s  %s\n' \
                    "$BOLD" "$idx" "$NC" "$domain" "WordPress" \
                    "$RED" "(no backup)" "$NC" "—" "—" "—"
            fi
        done
    fi

    # 2) Docker apps — Phase C will add backup; for now flag as not-yet
    if [[ -d "$MWP_APPS_DIR" ]] && ls "$MWP_APPS_DIR"/*.conf &>/dev/null 2>&1; then
        for conf in "$MWP_APPS_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            idx=$(( idx + 1 ))
            domain="$(grep '^DOMAIN=' "$conf" | cut -d= -f2-)"
            local name
            name="$(basename "$conf" .conf)"
            printf '  %b%-3s%b  %-32s  %-10s  %b%-16s%b  %-6s  %-6s  %s\n' \
                "$BOLD" "$idx" "$NC" "$domain" "Docker:$name" \
                "$YELLOW" "(Phase C todo)" "$NC" "—" "—" "⚠"
        done
    fi

    printf '  %s\n' "$(printf '─%.0s' {1..82})"
    if [[ -n "$target" ]]; then
        printf '  Offsite target:  %s\n' "$target"
    else
        printf '  Offsite target:  %b(none configured)%b — run: mwp backup gdrive setup\n' \
            "$YELLOW" "$NC"
    fi
    printf '\n'
}

# Convert seconds-since-epoch-delta into a human label like 5m / 3h / 2d / 14d.
_backup_human_age() {
    local sec=$1
    if   (( sec < 3600 ));  then printf '%dm' $(( sec / 60 ))
    elif (( sec < 86400 )); then printf '%dh' $(( sec / 3600 ))
    else                         printf '%dd' $(( sec / 86400 ))
    fi
}
