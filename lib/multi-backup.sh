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
}

# ---------------------------------------------------------------------------
# rotate old backups (keep N most recent)
# ---------------------------------------------------------------------------
_backup_rotate() {
    local dir="$1" domain="$2" type="$3" keep="$4"
    local files
    # shellcheck disable=SC2012
    files="$(ls -t "${dir}/${domain}-${type}-"* 2>/dev/null | tail -n +$(( keep + 1 )))"
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
    trap 'rm -rf "$tmp_dir"' EXIT

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
