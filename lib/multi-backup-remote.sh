#!/usr/bin/env bash
# lib/multi-backup-remote.sh — Offsite backup via rclone (P0b)
#
# Strategy:
#   - Lazy-install rclone on first use (small Go binary, no deps)
#   - rclone config lives at /root/.config/rclone/rclone.conf as usual
#   - mwp tracks the active "remote name" in /etc/mwp/server.conf as
#     BACKUP_REMOTE=<rclone-remote-name>:<bucket-or-path>
#   - After a successful local `mwp backup full`, push the archive via
#     `rclone copy` if BACKUP_REMOTE is set
#   - Survives ransomware: even if the VPS is encrypted in place, the
#     remote copy stays intact (especially with S3 Object Lock /
#     B2 lifecycle versioning).
#
# Public:
#   backup_remote_install        Install rclone (idempotent)
#   backup_remote_setup          Run interactive `rclone config`
#   backup_remote_set <remote>   Mark <remote> as the active offsite target
#   backup_remote_unset          Disable offsite uploads
#   backup_remote_status         Show config + last upload + remote disk usage
#   backup_remote_push <file>    Push one local file to the configured remote
#   backup_remote_list [domain]  List remote backups (filter by domain)
#   backup_remote_pull <name>    Download a remote archive into /tmp

[[ -n "${_MWP_BACKUP_REMOTE_LOADED:-}" ]] && return 0
_MWP_BACKUP_REMOTE_LOADED=1

# ---------------------------------------------------------------------------
# Install rclone from the official upstream installer (always latest stable).
# Ubuntu's apt rclone is months behind and missing newer providers (R2, etc.).
# ---------------------------------------------------------------------------
backup_remote_install() {
    require_root
    if command -v rclone >/dev/null 2>&1; then
        log_sub "rclone already installed: $(rclone --version | head -1)"
        return 0
    fi
    log_info "Installing rclone (latest from rclone.org)..."
    if ! curl -fsSL https://rclone.org/install.sh | bash 2>&1 | tail -3; then
        die "rclone install failed. Try: apt-get install -y rclone"
    fi
    log_success "rclone installed: $(rclone --version | head -1)"
}

# ---------------------------------------------------------------------------
# Run rclone's own interactive config wizard. We don't reinvent it — rclone
# supports 50+ providers and its UI is the canonical way to configure them.
# After it exits we tell the operator to point mwp at the new remote.
# ---------------------------------------------------------------------------
backup_remote_setup() {
    require_root
    backup_remote_install

    printf '\n%b  Offsite backup setup%b\n' "$BOLD" "$NC"
    printf '  %s\n' "──────────────────────────────────────"
    printf '  About to launch rclone config wizard. Steps:\n'
    printf '    1. n   (new remote)\n'
    printf '    2. Pick provider — recommended for ransomware survival:\n'
    printf '         %bbackblaze%b  (b2)  — cheapest + native versioning\n' "$GREEN" "$NC"
    printf '         %bs3%b         (aws / wasabi / cloudflare-r2 / minio)\n' "$GREEN" "$NC"
    printf '         %bgdrive%b     (Google Drive — convenient but no immutability)\n' "$YELLOW" "$NC"
    printf '         %bsftp%b       (any SSH-reachable host)\n' "$GREEN" "$NC"
    printf '    3. Follow the prompts (paste API keys when asked).\n'
    printf '    4. q   (quit)\n\n'
    printf '  After exit, run: %bmwp backup remote set <remote-name>:<bucket-or-path>%b\n\n' "$BOLD" "$NC"
    sleep 2
    rclone config
    printf '\n  Done. Remotes configured:\n'
    rclone listremotes 2>/dev/null | sed 's/^/    /'
    printf '\n  Next: mwp backup remote set <remote>:<bucket>\n\n'
}

# ---------------------------------------------------------------------------
# Mark a remote as the active offsite target. Validates by listing it once.
# ---------------------------------------------------------------------------
backup_remote_set() {
    require_root
    local target="${1:-}"
    [[ -z "$target" ]] && die "Usage: mwp backup remote set <remote>:<path>
       e.g. mwp backup remote set b2-backup:mwp-vps01-backups
            mwp backup remote set s3-prod:mybucket/mwp"
    [[ "$target" == *:* ]] || die "Target must be in form <remote>:<path>"

    command -v rclone >/dev/null 2>&1 || backup_remote_install

    log_info "Validating $target ..."
    if ! rclone lsd "$target" >/dev/null 2>&1 && \
       ! rclone mkdir "$target" 2>&1 | tail -3; then
        die "Cannot reach $target. Run: mwp backup remote setup (and verify token/bucket)."
    fi

    server_set "BACKUP_REMOTE" "$target"
    log_success "Offsite remote set: $target"
    log_sub "Future 'mwp backup full <domain>' will auto-push to this remote."
}

backup_remote_unset() {
    require_root
    server_set "BACKUP_REMOTE" ""
    log_success "Offsite uploads disabled."
}

# ---------------------------------------------------------------------------
# Push a single file to the configured remote. Path on remote is
#   <remote>:<path>/<hostname>/<basename>
# so backups from multiple VPS into one bucket stay separated.
# Called automatically by hook in lib/multi-backup.sh after a local backup.
# ---------------------------------------------------------------------------
backup_remote_push() {
    require_root
    local file="${1:-}"
    [[ -z "$file" || ! -f "$file" ]] && die "Usage: mwp backup remote push <local-file>"

    local target
    target="$(server_get "BACKUP_REMOTE")"
    [[ -z "$target" ]] && die "No remote configured. Run: mwp backup remote setup"

    command -v rclone >/dev/null 2>&1 || die "rclone not installed. Run: mwp backup remote install"

    local host_path
    host_path="${target}/$(hostname -s)"
    local size
    size="$(du -h "$file" 2>/dev/null | cut -f1)"

    log_info "Pushing $(basename "$file") (${size}) → ${host_path}/"
    if rclone copy "$file" "$host_path/" --progress --stats-one-line --stats=10s 2>&1 | tail -5; then
        server_set "BACKUP_REMOTE_LAST" "$(date '+%Y-%m-%d %H:%M:%S') $(basename "$file") ${size}"
        log_success "Uploaded to ${host_path}/$(basename "$file")"
    else
        log_error "rclone copy failed. Local backup is safe at: $file"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# List remote backups (optional domain filter)
# ---------------------------------------------------------------------------
backup_remote_list() {
    local filter="${1:-}"
    local target
    target="$(server_get "BACKUP_REMOTE")"
    [[ -z "$target" ]] && die "No remote configured. Run: mwp backup remote setup"
    command -v rclone >/dev/null 2>&1 || die "rclone not installed."

    local host_path="${target}/$(hostname -s)"
    printf '\n%b  Remote backups at %s%b\n' "$BOLD" "$host_path" "$NC"
    printf '  %s\n' "──────────────────────────────────────────────"
    if [[ -n "$filter" ]]; then
        rclone ls "$host_path" --include "*${filter}*" 2>/dev/null | sed 's/^/  /'
    else
        rclone ls "$host_path" 2>/dev/null | sed 's/^/  /' | head -50
    fi
    printf '\n'
}

# ---------------------------------------------------------------------------
# Pull a single archive from remote into /tmp for inspection or restore
# ---------------------------------------------------------------------------
backup_remote_pull() {
    require_root
    local archive="${1:-}"
    [[ -z "$archive" ]] && die "Usage: mwp backup remote pull <archive-name>"

    local target
    target="$(server_get "BACKUP_REMOTE")"
    [[ -z "$target" ]] && die "No remote configured."
    command -v rclone >/dev/null 2>&1 || die "rclone not installed."

    local host_path="${target}/$(hostname -s)"
    local dest="/tmp/${archive}"
    log_info "Pulling ${archive} → ${dest}"
    rclone copy "${host_path}/${archive}" /tmp/ --progress 2>&1 | tail -3
    [[ -f "$dest" ]] || die "Pull failed — file not at $dest"
    log_success "Downloaded: $dest ($(du -h "$dest" | cut -f1))"
    log_sub "To restore: mwp restore <domain> $dest"
}

backup_remote_status() {
    printf '\n%b  Offsite backup status%b\n' "$BOLD" "$NC"
    printf '  %s\n' "──────────────────────────────────────"

    local target last
    target="$(server_get "BACKUP_REMOTE")"
    last="$(server_get "BACKUP_REMOTE_LAST")"

    if ! command -v rclone >/dev/null 2>&1; then
        printf '  rclone:           %bnot installed%b  (run: mwp backup remote setup)\n\n' "$RED" "$NC"
        return 0
    fi
    printf '  rclone:           %s\n' "$(rclone --version | head -1)"

    if [[ -z "$target" ]]; then
        printf '  Remote:           %bnot configured%b  (run: mwp backup remote setup)\n\n' "$YELLOW" "$NC"
        return 0
    fi
    printf '  Remote:           %s\n' "$target"
    printf '  Hostname prefix:  %s\n' "$(hostname -s)"
    [[ -n "$last" ]] && printf '  Last upload:      %s\n' "$last"

    # Disk usage on remote (some providers don't support this — quietly skip)
    local du_info
    du_info="$( set +o pipefail; rclone size "${target}/$(hostname -s)" 2>/dev/null )"
    if [[ -n "$du_info" ]]; then
        printf '  Remote usage:\n'
        printf '%s\n' "$du_info" | sed 's/^/    /'
    fi
    printf '\n'
}
