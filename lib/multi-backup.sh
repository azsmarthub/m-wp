#!/usr/bin/env bash
# lib/multi-backup.sh — Per-site backup/restore for mwp

[[ -n "${_MWP_BACKUP_LOADED:-}" ]] && return 0
_MWP_BACKUP_LOADED=1

# ---------------------------------------------------------------------------
# backup_site <domain> <type: full|db|files>
# Output: /home/<user>/backups/<domain>-<type>-<date>.tar.gz
# ---------------------------------------------------------------------------
backup_site() {
    local domain="${1:-}" type="${2:-full}" tier="${3:-full}"
    [[ -z "$domain" ]] && die "Usage: mwp backup <full|db|files> <domain>"
    site_exists "$domain" || die "Site '$domain' not found."

    local site_user web_root db_name db_user db_pass backup_dir timestamp archive
    site_user="$(site_get "$domain" SITE_USER)"
    web_root="$(site_get "$domain" WEB_ROOT)"
    db_name="$(site_get "$domain" DB_NAME)"
    db_user="$(site_get "$domain" DB_USER)"
    db_pass="$(site_get "$domain" DB_PASS)"
    backup_dir="/home/${site_user}/backups"

    # File-naming convention.
    # Manual `mwp backup full <dom>` uses tier="full" with HHMMSS so multiple
    # manual runs in one day don't overwrite each other.
    # Scheduled runs pass tier=daily|weekly|monthly with date-only naming so
    # at most one file per day per tier exists (predictable for rotation).
    if [[ "$tier" == "full" ]]; then
        timestamp="$(date '+%Y%m%d-%H%M%S')"
    else
        timestamp="$(date '+%Y%m%d')"
    fi

    # Archive slug used both for the filename "type" segment and for rotation
    # bucket. For db/files types we keep "db"/"files" regardless of tier
    # (tiered scheduling only applies to "full").
    local arch_slug
    case "$type" in
        full)  arch_slug="$tier" ;;
        db)    arch_slug="db" ;;
        files) arch_slug="files" ;;
        *)     die "Unknown backup type: $type. Use: full | db | files" ;;
    esac

    mkdir -p "$backup_dir"
    log_info "Backing up ${domain} (${type}, tier=${tier})..."

    case "$type" in
        full)
            archive="${backup_dir}/${domain}-${arch_slug}-${timestamp}.tar.gz"

            # 1. Dump DB
            local db_dump="/tmp/mwp-db-${domain}-${timestamp}.sql"
            log_sub "Dumping database..."
            mysqldump --single-transaction --quick --skip-lock-tables \
                -u "$db_user" -p"$db_pass" "$db_name" > "$db_dump" 2>/dev/null || \
                die "mysqldump failed for $db_name"

            # 2. Archive files + db dump.
            # tar exit codes:
            #   0  success
            #   1  some files changed/disappeared during read (e.g. cache
            #      files updated mid-tar) — archive is valid, just warn
            #   2+ fatal error — archive is suspect
            # The previous `|| die` treated warnings as fatal, which broke
            # bs-doctor.com (busy WordPress with active page cache writes).
            log_sub "Archiving files..."
            local _rc=0
            tar czf "$archive" \
                -C "$(dirname "$web_root")" "$(basename "$web_root")" \
                -C /tmp "$(basename "$db_dump")" \
                2>/dev/null || _rc=$?
            if (( _rc >= 2 )); then
                rm -f "$db_dump"
                die "tar archive failed (exit $_rc)"
            elif (( _rc == 1 )); then
                log_warn "tar exit 1 — some files changed during read (archive is valid)"
            fi

            rm -f "$db_dump"
            ;;

        db)
            archive="${backup_dir}/${domain}-${arch_slug}-${timestamp}.sql.gz"
            log_sub "Dumping database..."
            mysqldump --single-transaction --quick --skip-lock-tables \
                -u "$db_user" -p"$db_pass" "$db_name" 2>/dev/null | \
                gzip > "$archive" || die "Database dump failed"
            ;;

        files)
            archive="${backup_dir}/${domain}-${arch_slug}-${timestamp}.tar.gz"
            log_sub "Archiving files (no DB)..."
            local _rc=0
            tar czf "$archive" \
                -C "$(dirname "$web_root")" "$(basename "$web_root")" \
                2>/dev/null || _rc=$?
            if (( _rc >= 2 )); then
                die "tar archive failed (exit $_rc)"
            elif (( _rc == 1 )); then
                log_warn "tar exit 1 — files changed during read (archive is valid)"
            fi
            ;;
    esac

    chown "${site_user}:${site_user}" "$archive"
    local size
    size="$(du -sh "$archive" 2>/dev/null | cut -f1)"
    log_success "Backup saved: $archive (${size})"

    # Tiered rotation. Each tier has its own keep-count from server.conf,
    # so daily/weekly/monthly age out independently.
    local keep_for_tier
    case "$arch_slug" in
        daily)   keep_for_tier="$(server_get BACKUP_KEEP_DAILY 2>/dev/null   || true)"; keep_for_tier="${keep_for_tier:-7}" ;;
        weekly)  keep_for_tier="$(server_get BACKUP_KEEP_WEEKLY 2>/dev/null  || true)"; keep_for_tier="${keep_for_tier:-4}" ;;
        monthly) keep_for_tier="$(server_get BACKUP_KEEP_MONTHLY 2>/dev/null || true)"; keep_for_tier="${keep_for_tier:-12}" ;;
        full)    keep_for_tier="$(server_get BACKUP_KEEP_FULL 2>/dev/null    || true)"; keep_for_tier="${keep_for_tier:-7}" ;;
        db)      keep_for_tier="$(server_get BACKUP_KEEP_DB 2>/dev/null      || true)"; keep_for_tier="${keep_for_tier:-14}" ;;
        files)   keep_for_tier="$(server_get BACKUP_KEEP_FILES 2>/dev/null   || true)"; keep_for_tier="${keep_for_tier:-7}" ;;
    esac
    _backup_rotate "$backup_dir" "$domain" "$arch_slug" "$keep_for_tier"

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
    printf '  %s\n' "$(printf '─%.0s' {1..86})"
    printf '  %b%-3s  %-32s  %-14s  %-16s  %-6s  %-6s  %s%b\n' \
        "$BOLD" "#" "ENTITY" "TYPE" "LATEST BACKUP" "AGE" "SIZE" "OFFSITE" "$NC"
    printf '  %s\n' "$(printf '─%.0s' {1..86})"

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

    # 1) WordPress sites — check ALL tier files (full + daily + weekly + monthly)
    # not just *-full-*. Scheduled runs use tier-named files now.
    if [[ -d "$MWP_SITES_DIR" ]] && ls "$MWP_SITES_DIR"/*.conf &>/dev/null 2>&1; then
        for conf in "$MWP_SITES_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            idx=$(( idx + 1 ))
            domain="$(grep '^DOMAIN=' "$conf" | cut -d= -f2-)"
            user="$(grep '^SITE_USER=' "$conf" | cut -d= -f2-)"
            bdir="/home/${user}/backups"
            latest="$(_backup_latest_for "$bdir" "$domain")"
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
                printf '  %b%-3s%b  %-32s  %-14s  %-16s  %-6s  %-6s  %s\n' \
                    "$BOLD" "$idx" "$NC" "$(_trunc "$domain" 32)" "WordPress" \
                    "$date_str" "$age_col" "$size" "$offsite_col"
            else
                printf '  %b%-3s%b  %-32s  %-14s  %b%-16s%b  %-6s  %-6s  %s\n' \
                    "$BOLD" "$idx" "$NC" "$(_trunc "$domain" 32)" "WordPress" \
                    "$RED" "(no backup)" "$NC" "—" "—" "—"
            fi
        done
    fi

    # 2) Docker apps — registered via `mwp app create` or `mwp app register`
    if [[ -d "$MWP_APPS_DIR" ]] && ls "$MWP_APPS_DIR"/*.conf &>/dev/null 2>&1; then
        for conf in "$MWP_APPS_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            idx=$(( idx + 1 ))
            domain="$(grep '^DOMAIN=' "$conf" | cut -d= -f2-)"
            local name
            name="$(basename "$conf" .conf)"
            local app_bdir="/var/lib/mwp/app-backups/$name"
            latest="$(_backup_latest_for "$app_bdir" "$name")"
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
                        *)            offsite_col="${RED}✗${NC}" ;;
                    esac
                fi
                local age_col
                if   (( age_sec > 7*86400 )); then age_col="${RED}${age_str}${NC}"
                elif (( age_sec > 3*86400 )); then age_col="${YELLOW}${age_str}${NC}"
                else                               age_col="${GREEN}${age_str}${NC}"
                fi
                printf '  %b%-3s%b  %-32s  %-14s  %-16s  %-6s  %-6s  %s\n' \
                    "$BOLD" "$idx" "$NC" "$(_trunc "${domain:-$name}" 32)" \
                    "$(_trunc "Docker:$name" 14)" \
                    "$date_str" "$age_col" "$size" "$offsite_col"
            else
                printf '  %b%-3s%b  %-32s  %-14s  %b%-16s%b  %-6s  %-6s  %s\n' \
                    "$BOLD" "$idx" "$NC" "$(_trunc "${domain:-$name}" 32)" \
                    "$(_trunc "Docker:$name" 14)" \
                    "$RED" "(no backup)" "$NC" "—" "—" "—"
            fi
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

# Find the newest backup file for a domain/app under <dir>, across ALL tier
# names (full / daily / weekly / monthly). Echoes path or empty if none.
# Wrapped in subshell-with-pipefail-off because `ls` no-match is normal
# when an entity has never been backed up — we treat as "empty result".
_backup_latest_for() {
    local dir="$1" name="$2"
    [[ -d "$dir" ]] || { return 0; }
    ( set +o pipefail
      ls -t "${dir}/${name}-"{full,daily,weekly,monthly}-*".tar.gz" \
            "${dir}/${name}-"{full,daily,weekly,monthly}-*".sql.gz" \
        2>/dev/null | head -1 )
}

# Convert seconds-since-epoch-delta into a human label like 5m / 3h / 2d / 14d.
_backup_human_age() {
    local sec=$1
    if   (( sec < 3600 ));  then printf '%dm' $(( sec / 60 ))
    elif (( sec < 86400 )); then printf '%dh' $(( sec / 3600 ))
    else                         printf '%dd' $(( sec / 86400 ))
    fi
}

# ---------------------------------------------------------------------------
# backup_all_scheduled — entry point called by mwp-backup.service
#
# Decides tier from today's date:
#   day-of-month == 1   →  monthly   (one file/site/month, kept for KEEP_MONTHLY)
#   else day-of-week == 7 (Sun) → weekly  (kept for KEEP_WEEKLY)
#   else                →  daily     (kept for KEEP_DAILY)
#
# Iterates every site in /etc/mwp/sites/ and runs backup_site full <tier>.
# Each site's failure is logged but does NOT abort the run — partial
# success is better than zero coverage when one site is broken.
#
# Output goes to STDOUT/STDERR which systemd appends to
#   /var/log/mwp/backup-cron.log
# ---------------------------------------------------------------------------
backup_all_scheduled() {
    require_root

    local dom dow tier
    dom="$(date +%-d)"     # 1-31
    dow="$(date +%u)"      # 1-7, Mon=1 ... Sun=7

    if   [[ "$dom" == "1" ]]; then tier="monthly"
    elif [[ "$dow" == "7" ]]; then tier="weekly"
    else                           tier="daily"
    fi

    printf '\n══════════════════════════════════════════════════════════════════\n'
    printf '  mwp scheduled backup run\n'
    printf '  Started:  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '  Tier:     %s  (dom=%s dow=%s)\n' "$tier" "$dom" "$dow"
    printf '  Schedule: %s\n' "$(server_get BACKUP_SCHEDULE 2>/dev/null || echo '?')"
    printf '══════════════════════════════════════════════════════════════════\n\n'

    local conf domain ok=0 fail=0 start_ts end_ts app_ok=0 app_fail=0
    start_ts="$(date +%s)"

    # ─── 1) WordPress sites ─────────────────────────────────────────
    # CRITICAL: backup_site / backup_app call `die` on internal failure,
    # and `die` does `exit 1` which kills the whole script — not just
    # the function. Plain `if backup_site ...; then` does NOT catch
    # that because `exit` propagates past `if`. Wrap the call in a
    # SUBSHELL so the exit only kills the subshell; the parent loop
    # picks up the non-zero status and moves to the next site/app.
    if [[ -d "$MWP_SITES_DIR" ]] && ls "$MWP_SITES_DIR"/*.conf &>/dev/null 2>&1; then
        printf '  Phase 1/2: WordPress sites\n'
        for conf in "$MWP_SITES_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            domain="$(grep '^DOMAIN=' "$conf" | cut -d= -f2-)"
            [[ -z "$domain" ]] && continue
            printf '\n──── site: %s ────\n' "$domain"
            if ( backup_site "$domain" "full" "$tier" ); then
                ok=$(( ok + 1 ))
            else
                fail=$(( fail + 1 ))
                printf '  ⚠ FAILED: %s — see log above\n' "$domain"
            fi
        done
    else
        printf '  No sites registered — skipping site phase.\n'
    fi

    # ─── 2) Docker apps ─────────────────────────────────────────────
    if [[ -d "$MWP_APPS_DIR" ]] && ls "$MWP_APPS_DIR"/*.conf &>/dev/null 2>&1; then
        printf '\n  Phase 2/2: Docker apps\n'
        [[ -n "${_MWP_APP_BACKUP_LOADED:-}" ]] || \
            source "$MWP_DIR/lib/multi-app-backup.sh"
        for conf in "$MWP_APPS_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            local app_name
            app_name="$(basename "$conf" .conf)"
            printf '\n──── app: %s ────\n' "$app_name"
            if ( backup_app "$app_name" "$tier" ); then
                app_ok=$(( app_ok + 1 ))
            else
                app_fail=$(( app_fail + 1 ))
                printf '  ⚠ FAILED: %s — see log above\n' "$app_name"
            fi
        done
    fi

    end_ts="$(date +%s)"
    local elapsed=$(( end_ts - start_ts ))

    printf '\n══════════════════════════════════════════════════════════════════\n'
    printf '  Run finished: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '  Elapsed:      %dm %ds\n' $(( elapsed / 60 )) $(( elapsed % 60 ))
    printf '  Sites:        %d ok, %d failed\n' "$ok" "$fail"
    printf '  Apps:         %d ok, %d failed\n' "$app_ok" "$app_fail"
    printf '══════════════════════════════════════════════════════════════════\n'

    # Combined fail count for return status + last-result tracking
    fail=$(( fail + app_fail ))
    ok=$(( ok + app_ok ))

    server_set "BACKUP_LAST_RUN"   "$(date '+%Y-%m-%d %H:%M:%S')"
    server_set "BACKUP_LAST_TIER"  "$tier"
    server_set "BACKUP_LAST_RESULT" "${ok}ok/${fail}fail"

    [[ $fail -gt 0 ]] && return 1 || return 0
}
