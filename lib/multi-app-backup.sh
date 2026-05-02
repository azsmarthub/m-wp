#!/usr/bin/env bash
# lib/multi-app-backup.sh — Backup + restore for Docker apps
#
# Two app categories:
#   1. mwp-created     created via `mwp app create` — full config in registry
#   2. external        pre-existing Docker (compose / docker run) — needs
#                      `mwp app register` to add it to /etc/mwp/apps/
#
# Backup strategy (works for both categories):
#   1. `docker inspect` → save container config as JSON inside the archive
#   2. (optional) `docker stop` for consistent snapshot — esp. for DBs
#   3. tar all bind-mount sources directly
#   4. for each named volume: `docker run --rm -v <vol>:/data alpine tar cf -`
#      to stream the volume contents into the archive
#   5. `docker start` to restore service
#   6. rotate per tier (same logic as backup_site)
#   7. auto-push to offsite if BACKUP_REMOTE set
#
# Backup destination: /var/lib/mwp/app-backups/<name>/
#   (separate from /var/lib/mwp/apps/<name>/ which is data dir for
#    mwp-created apps — we don't want backups co-located with data)

[[ -n "${_MWP_APP_BACKUP_LOADED:-}" ]] && return 0
_MWP_APP_BACKUP_LOADED=1

APP_BACKUP_ROOT="/var/lib/mwp/app-backups"

# ---------------------------------------------------------------------------
# Public entries
# ---------------------------------------------------------------------------

# backup_app <name> [tier]
backup_app() {
    require_root

    # Lazy-load deps the first time
    [[ -n "${_MWP_APP_REGISTRY_LOADED:-}" ]] || \
        source "$MWP_DIR/lib/app-registry.sh"

    local name="${1:-}" tier="${2:-full}"
    [[ -z "$name" ]] && die "Usage: mwp app backup <name> [tier]"
    app_exists "$name" || \
        die "App '$name' not registered. To register an external Docker container:
   mwp app register $name"

    command -v docker >/dev/null 2>&1 || die "docker CLI not installed"

    local container backup_stop image domain
    container="$(app_get "$name" CONTAINER)"
    backup_stop="$(app_get "$name" BACKUP_STOP)"
    [[ -z "$backup_stop" ]] && backup_stop="yes"
    image="$(app_get "$name" IMAGE)"
    domain="$(app_get "$name" DOMAIN)"
    [[ -z "$container" ]] && die "App '$name' has no CONTAINER set in registry"

    # Verify container exists in docker (registered ≠ live)
    docker inspect "$container" >/dev/null 2>&1 \
        || die "Container '$container' not found in docker. Was it removed?"

    local backup_dir="$APP_BACKUP_ROOT/$name"
    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir"

    # File naming follows the same convention as backup_site
    local timestamp
    if [[ "$tier" == "full" ]]; then
        timestamp="$(date '+%Y%m%d-%H%M%S')"
    else
        timestamp="$(date '+%Y%m%d')"
    fi
    local archive="$backup_dir/${name}-${tier}-${timestamp}.tar.gz"

    log_info "Backing up app '$name' (container=$container, tier=$tier)"

    # ── Step 1: stage everything into a tmp dir we'll tar at the end ───
    local stage; stage="$(mktemp -d "/tmp/mwp-app-backup-${name}-XXXXXX")"
    chmod 700 "$stage"
    # Trap cleanup — even if we die mid-way, the tmp dir gets removed
    # shellcheck disable=SC2064
    trap "rm -rf '$stage'" EXIT

    # 1a. Container config snapshot
    log_sub "Saving container config (docker inspect → meta.json)..."
    docker inspect "$container" > "$stage/meta.json" \
        || die "docker inspect failed for $container"

    # Also write a small recovery script so a human reading the archive
    # in 6 months knows how to restore it.
    cat > "$stage/RESTORE.txt" <<RESTORE_HELP
mwp app backup archive
======================
App name:    $name
Container:   $container
Image:       $image
Domain:      $domain
Tier:        $tier
Created:     $(date '+%Y-%m-%d %H:%M:%S %Z')
Hostname:    $(hostname -f 2>/dev/null || hostname)

Contents:
  meta.json         docker inspect output (full container config)
  bind/             bind-mount sources (preserves absolute paths)
  volumes/          one .tar per named volume

To restore:
  mwp app restore $name <this-file>
RESTORE_HELP

    # ── Step 2: stop container if configured (consistent snapshot) ───
    local was_running="no"
    if docker ps --filter "name=^${container}$" --format '{{.Names}}' \
       2>/dev/null | grep -q .; then
        was_running="yes"
    fi

    if [[ "$backup_stop" == "yes" && "$was_running" == "yes" ]]; then
        log_sub "Stopping container for consistent snapshot..."
        docker stop "$container" >/dev/null 2>&1 \
            || log_warn "docker stop failed — proceeding with hot backup"
    fi

    # ── Step 3: collect bind mounts ───
    mkdir -p "$stage/bind"
    local bind_count=0
    while IFS= read -r src; do
        [[ -z "$src" ]] && continue
        if [[ ! -e "$src" ]]; then
            log_warn "Bind source missing: $src — skipping"
            continue
        fi
        # Mirror absolute path under stage/bind so restore knows where it came from
        local rel_dst="$stage/bind${src}"
        mkdir -p "$(dirname "$rel_dst")"
        cp -a "$src" "$rel_dst"
        bind_count=$(( bind_count + 1 ))
        log_sub "  bind: $src"
    done < <(_app_list_bind_sources "$container")

    # ── Step 4: export named volumes ───
    mkdir -p "$stage/volumes"
    local vol_count=0
    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue
        log_sub "  volume: $vol → tar"
        # Use alpine to tar the volume contents. Pull is auto-cached after
        # first run. Stream directly to a tar file in stage/volumes/.
        if ! docker run --rm \
                -v "${vol}:/data:ro" \
                -v "${stage}/volumes:/out" \
                alpine \
                tar cf "/out/${vol}.tar" -C /data . 2>/dev/null; then
            log_warn "Volume export failed: $vol — continuing"
            continue
        fi
        vol_count=$(( vol_count + 1 ))
    done < <(_app_list_volume_names "$container")

    # ── Step 5: restart container if we stopped it ───
    if [[ "$backup_stop" == "yes" && "$was_running" == "yes" ]]; then
        log_sub "Restarting container..."
        docker start "$container" >/dev/null 2>&1 \
            || log_warn "docker start failed — container may need manual restart"
    fi

    # ── Step 6: archive everything ───
    log_sub "Compressing archive..."
    if ! tar czf "$archive" -C "$stage" . 2>/dev/null; then
        die "tar failed: $archive"
    fi
    chmod 600 "$archive"

    # cleanup is handled by trap; clear it so we can return success
    trap - EXIT
    rm -rf "$stage"

    local size
    size="$(du -sh "$archive" 2>/dev/null | cut -f1)"
    log_success "App backup saved: $archive ($size, ${bind_count} bind, ${vol_count} volumes)"

    # ── Step 7: rotate per tier ───
    local keep_for_tier
    case "$tier" in
        daily)   keep_for_tier="$(server_get BACKUP_KEEP_DAILY 2>/dev/null   || true)"; keep_for_tier="${keep_for_tier:-7}" ;;
        weekly)  keep_for_tier="$(server_get BACKUP_KEEP_WEEKLY 2>/dev/null  || true)"; keep_for_tier="${keep_for_tier:-4}" ;;
        monthly) keep_for_tier="$(server_get BACKUP_KEEP_MONTHLY 2>/dev/null || true)"; keep_for_tier="${keep_for_tier:-12}" ;;
        full)    keep_for_tier="$(server_get BACKUP_KEEP_FULL 2>/dev/null    || true)"; keep_for_tier="${keep_for_tier:-7}" ;;
    esac
    _backup_rotate "$backup_dir" "$name" "$tier" "$keep_for_tier"

    # ── Step 8: auto-push offsite ───
    if [[ -n "$(server_get BACKUP_REMOTE 2>/dev/null || true)" ]]; then
        [[ -n "${_MWP_BACKUP_REMOTE_LOADED:-}" ]] || \
            source "$MWP_DIR/lib/multi-backup-remote.sh"
        backup_remote_push "$archive" || \
            log_warn "Offsite push failed — local copy intact"
    fi
}

# ---------------------------------------------------------------------------
# app_register <name> — register an external (pre-existing) Docker container
# so backup_app + scheduled runs can include it.
# ---------------------------------------------------------------------------
app_register() {
    require_root
    [[ -n "${_MWP_APP_REGISTRY_LOADED:-}" ]] || \
        source "$MWP_DIR/lib/app-registry.sh"

    local container="${1:-}"
    [[ -z "$container" ]] && die "Usage: mwp app register <container-name>
   List candidates: docker ps --format '{{.Names}}'"
    command -v docker >/dev/null 2>&1 || die "docker CLI not installed"
    docker inspect "$container" >/dev/null 2>&1 \
        || die "No Docker container named '$container'"

    # Auto-detect image, prompt for the rest
    local image domain stop_policy port host_port
    image="$(docker inspect "$container" --format '{{.Config.Image}}')"
    # First exposed port → use as INTERNAL_PORT
    port="$(docker inspect "$container" \
            --format '{{range $p, $_ := .Config.ExposedPorts}}{{$p}} {{end}}' 2>/dev/null \
            | awk '{print $1}' | cut -d/ -f1)"
    host_port="$(docker port "$container" 2>/dev/null \
                 | awk -F: '{print $NF}' | head -1)"

    printf '\n%b  Register external Docker app%b\n' "$BOLD" "$NC"
    printf '  %s\n' "─────────────────────────────────────────────────────"
    printf '  Container:    %s\n' "$container"
    printf '  Image:        %s\n' "$image"
    [[ -n "$port"      ]] && printf '  Internal port: %s\n' "$port"
    [[ -n "$host_port" ]] && printf '  Host port:     %s\n' "$host_port"

    printf '\n  Detected mounts:\n'
    docker inspect "$container" \
        --format '{{range .Mounts}}    {{.Type}}: {{.Source}}{{if eq .Type "volume"}} (vol={{.Name}}){{end}} → {{.Destination}}{{println}}{{end}}'

    printf '  Domain (e.g. n8n.example.com, ENTER for none): '
    read -r domain
    [[ "$domain" == *"<---"* ]] && die "Paste-marker detected in domain — type it manually."

    printf '  Stop container during backup for consistency? [Y/n]\n'
    printf '    (recommended for SQLite/Postgres/MySQL inside container, db corruption risk if no): '
    read -r stop_policy
    case "${stop_policy,,}" in n|no) stop_policy="no" ;; *) stop_policy="yes" ;; esac

    # Save to registry
    local conf="$MWP_APPS_DIR/${container}.conf"
    if [[ -f "$conf" ]]; then
        log_warn "App '$container' already registered — overwriting."
    fi
    mkdir -p "$MWP_APPS_DIR"
    cat > "$conf" <<EOF
NAME=${container}
DOMAIN=${domain}
IMAGE=${image}
INTERNAL_PORT=${port}
HOST_PORT=${host_port}
CONTAINER=${container}
RUNTIME=docker
SOURCE_TYPE=external
EXTERNAL=yes
BACKUP_STOP=${stop_policy}
STATUS=registered
CREATED_AT=$(date '+%Y-%m-%d %H:%M:%S')
EOF
    chmod 600 "$conf"

    log_success "Registered: $container"
    log_sub "Config:        $conf"
    log_sub "Backup target: $APP_BACKUP_ROOT/$container/"
    log_sub "Test backup:   mwp app backup $container"
}

# ---------------------------------------------------------------------------
# restore_app <name> <archive>
# Best-effort restore: extracts bind mounts back to original paths,
# imports volume tars back into named volumes. Container itself is NOT
# recreated automatically — operator must docker-compose up / docker run
# afterwards. Container config is in meta.json for reference.
# ---------------------------------------------------------------------------
restore_app() {
    require_root
    [[ -n "${_MWP_APP_REGISTRY_LOADED:-}" ]] || \
        source "$MWP_DIR/lib/app-registry.sh"

    local name="${1:-}" archive="${2:-}"
    [[ -z "$name" || -z "$archive" ]] && die "Usage: mwp app restore <name> <archive>"
    [[ -f "$archive" ]] || die "Archive not found: $archive"
    app_exists "$name" || die "App '$name' not registered"

    local container
    container="$(app_get "$name" CONTAINER)"

    printf '\n%bRestore app: %s%b\n' "$YELLOW" "$name" "$NC"
    printf 'From: %s\n' "$archive"
    printf '\n  Will:\n'
    printf '    1. Stop container %s (if running)\n' "$container"
    printf '    2. Restore bind-mount paths from archive (overwrites)\n'
    printf '    3. Restore named volumes from archive (overwrites)\n'
    printf '    4. Restart container\n\n'
    printf '  Continue? (y/N): '
    local _c; read -r _c
    [[ "${_c,,}" != "y" ]] && { log_info "Aborted."; return 0; }

    local stage; stage="$(mktemp -d "/tmp/mwp-app-restore-${name}-XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$stage'" EXIT

    log_info "Extracting archive..."
    tar xzf "$archive" -C "$stage" || die "tar extraction failed"

    # Stop container
    log_sub "Stopping container..."
    local was_running="no"
    docker ps --filter "name=^${container}$" --format '{{.Names}}' 2>/dev/null \
        | grep -q . && was_running="yes"
    [[ "$was_running" == "yes" ]] && docker stop "$container" >/dev/null 2>&1 || true

    # Restore bind mounts
    if [[ -d "$stage/bind" ]]; then
        log_sub "Restoring bind mounts (rsync)..."
        # cp -a from stage/bind/ — paths inside mirror absolute paths
        if command -v rsync >/dev/null 2>&1; then
            rsync -a "$stage/bind/" / 2>/dev/null
        else
            # Fallback — cp -a (less efficient but works)
            cp -a "$stage/bind/." / 2>/dev/null
        fi
    fi

    # Restore named volumes
    if [[ -d "$stage/volumes" ]]; then
        for tarf in "$stage/volumes/"*.tar; do
            [[ -f "$tarf" ]] || continue
            local vol
            vol="$(basename "$tarf" .tar)"
            log_sub "Restoring volume: $vol"
            # Ensure volume exists
            docker volume create "$vol" >/dev/null 2>&1 || true
            # Import: tar into the volume by mounting it
            docker run --rm \
                -v "${vol}:/data" \
                -v "${stage}/volumes:/in:ro" \
                alpine \
                sh -c "rm -rf /data/* /data/.[!.]* 2>/dev/null; tar xf /in/${vol}.tar -C /data" \
                2>/dev/null || log_warn "Volume restore failed: $vol"
        done
    fi

    # Restart container
    if [[ "$was_running" == "yes" ]]; then
        log_sub "Restarting container..."
        docker start "$container" >/dev/null 2>&1 \
            || log_warn "Container restart failed — start manually"
    fi

    trap - EXIT
    rm -rf "$stage"
    log_success "App '$name' restored from $(basename "$archive")"
    log_sub "Verify with: docker logs $container"
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# List bind-mount source paths for a container (one per line)
_app_list_bind_sources() {
    local container="$1"
    docker inspect "$container" \
        --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{println}}{{end}}{{end}}' \
        2>/dev/null | sed '/^$/d'
}

# List named volume names for a container (one per line)
_app_list_volume_names() {
    local container="$1"
    docker inspect "$container" \
        --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{println}}{{end}}{{end}}' \
        2>/dev/null | sed '/^$/d'
}
