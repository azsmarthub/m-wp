#!/usr/bin/env bash
# lib/menu/apps.sh — Docker apps menu (Level 1) + per-app detail (Level 2)
#
# A "Docker app" in mwp is a single container (Next.js, n8n, Ghost, n8n,
# any Node repo, etc.) fronted by an nginx reverse proxy on a domain.
# This menu wraps lib/multi-app.sh + lib/multi-docker.sh into an
# interactive flow.

[[ -n "${_MWP_MENU_APPS_LOADED:-}" ]] && return 0
_MWP_MENU_APPS_LOADED=1

# Globals populated when listing apps for selection
MENU_APPS=()

# Load Docker-app libs the first time the menu is opened.
_menu_apps_lazy_load() {
    [[ -n "${_MWP_APP_LOADED:-}" ]] && return
    source "$MWP_DIR/lib/multi-docker.sh"
    source "$MWP_DIR/lib/app-registry.sh"
    source "$MWP_DIR/lib/multi-nginx.sh"
    source "$MWP_DIR/lib/multi-app.sh"
}

# ──────────────────────────────────────────────────────────────────────
# Apps table — populates MENU_APPS[] for numeric selection.
# Distinct from _entities_table: this is apps-only (used by menu_apps).
# ──────────────────────────────────────────────────────────────────────

_apps_table() {
    local _conf _name _d _img _port _container _live="?" _st_col _idx=0
    MENU_APPS=()

    printf '\n'
    printf '  %b%-3s  %-18s  %-30s  %-9s  %-7s  %s%b\n' \
        "$BOLD" "#" "NAME" "DOMAIN" "STATUS" "PORT" "IMAGE" "$NC"
    _mhr

    if [[ ! -d "$MWP_APPS_DIR" ]] || ! ls "$MWP_APPS_DIR"/*.conf &>/dev/null 2>&1; then
        printf '  (no apps yet — press [c] to create one)\n'
        _mhr; return 0
    fi

    for _conf in "$MWP_APPS_DIR"/*.conf; do
        [[ -f "$_conf" ]] || continue
        _name="$(basename "$_conf" .conf)"
        _d="$(grep   "^DOMAIN="    "$_conf" | cut -d= -f2-)"
        _img="$(grep "^IMAGE="     "$_conf" | cut -d= -f2-)"
        _port="$(grep "^HOST_PORT=" "$_conf" | cut -d= -f2-)"
        _container="$(grep "^CONTAINER=" "$_conf" | cut -d= -f2-)"

        _idx=$(( _idx + 1 ))
        MENU_APPS+=("$_name")

        _live="?"
        if command -v docker >/dev/null 2>&1 && [[ -n "$_container" ]]; then
            if docker ps --filter "name=^${_container}$" --format '{{.Names}}' 2>/dev/null | grep -q .; then
                _live="running"
            elif docker ps -a --filter "name=^${_container}$" --format '{{.Names}}' 2>/dev/null | grep -q .; then
                _live="stopped"
            else
                _live="missing"
            fi
        fi
        case "$_live" in
            running) _st_col="$(printf '%brunning  %b' "$GREEN"  "$NC")" ;;
            stopped) _st_col="$(printf '%bstopped  %b' "$YELLOW" "$NC")" ;;
            missing) _st_col="$(printf '%bmissing  %b' "$RED"    "$NC")" ;;
            *)       _st_col="$(printf '%b%-9s%b'      "$BOLD"   "$_live" "$NC")" ;;
        esac

        printf '  %b%-3s%b  %-18s  %-30s  %s  :%-6s %s\n' \
            "$BOLD" "$_idx" "$NC" "$_name" "$_d" "$_st_col" "$_port" "$_img"
    done
    _mhr
}

# ──────────────────────────────────────────────────────────────────────
# Level 1 — Apps list
# ──────────────────────────────────────────────────────────────────────

menu_apps() {
    _menu_apps_lazy_load

    _mheader "Docker Apps"

    # Engine status banner (one line)
    local engine="not installed"
    if command -v docker >/dev/null 2>&1; then
        if systemctl is-active --quiet docker 2>/dev/null; then
            engine="running ($(docker --version 2>/dev/null | cut -d, -f1))"
        else
            engine="installed but stopped"
        fi
    fi
    printf '  Docker engine: %s\n' "$engine"

    _apps_table

    # Hint about external (unregistered) containers — those visible to docker
    # but not in /etc/mwp/apps/. They CAN be brought under mwp's backup
    # umbrella via `mwp app register <name>`.
    if command -v docker >/dev/null 2>&1; then
        local _ext_count
        _ext_count="$( set +o pipefail
                       docker ps --format '{{.Names}}' 2>/dev/null \
                         | grep -vxFf <(ls "$MWP_APPS_DIR" 2>/dev/null | sed 's/\.conf$//') \
                         | wc -l )" || _ext_count=0
        if [[ "${_ext_count:-0}" -gt 0 ]]; then
            printf '  %b%s external container(s)%b not registered with mwp — see [r] below\n' \
                "$YELLOW" "$_ext_count" "$NC"
        fi
    fi

    if ! command -v docker >/dev/null 2>&1; then
        printf '  %b[i]%b  Install Docker engine\n' "$BOLD" "$NC"
    fi
    printf '  %b[c]%b  Create new app   %b[r]%b  Register external container   %b[d]%b  Engine status   %b[0]%b  Back\n' \
        "$BOLD" "$NC" "$BOLD" "$NC" "$BOLD" "$NC" "$BOLD" "$NC"
    _mprompt "App # or action"

    case "$MENU_INPUT" in
        0|back) menu_root; return ;;
        c|create) _menu_app_create_wizard; menu_apps ;;
        r|register) _menu_app_register; menu_apps ;;
        d|docker)
            _mc; docker_engine_status; _mpause; menu_apps
            ;;
        i|install)
            require_root
            _mc; docker_engine_install; _mpause; menu_apps
            ;;
        '') menu_apps ;;
        *)
            if [[ "$MENU_INPUT" =~ ^[0-9]+$ ]] && \
               [[ $MENU_INPUT -ge 1 && $MENU_INPUT -le ${#MENU_APPS[@]} ]]; then
                menu_app_detail "${MENU_APPS[$((MENU_INPUT-1))]}"
                menu_apps
            else
                menu_apps
            fi
            ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Level 2 — App detail
# ──────────────────────────────────────────────────────────────────────

menu_app_detail() {
    local name="$1"
    _menu_apps_lazy_load
    app_exists "$name" || { log_warn "App '$name' not found."; return; }

    local _d _img _port _intport _mem _container _data _cf _ssl _live="?"
    _d="$(app_get        "$name" DOMAIN)"
    _img="$(app_get      "$name" IMAGE)"
    _port="$(app_get     "$name" HOST_PORT)"
    _intport="$(app_get  "$name" INTERNAL_PORT)"
    _mem="$(app_get      "$name" MEMORY_LIMIT)"
    _container="$(app_get "$name" CONTAINER)"
    _data="$(app_get     "$name" DATA_DIR)"
    _cf="$(app_get       "$name" CF_PROXIED)"
    _ssl="$(_ssl_icon    "$_d")"

    if command -v docker >/dev/null 2>&1; then
        if docker ps --filter "name=^${_container}$" --format '{{.Names}}' 2>/dev/null | grep -q .; then
            _live="running"
        elif docker ps -a --filter "name=^${_container}$" --format '{{.Names}}' 2>/dev/null | grep -q .; then
            _live="stopped"
        else
            _live="missing"
        fi
    fi

    local _toggle="Start" _live_col
    [[ "$_live" == "running" ]] && _toggle="Stop"
    case "$_live" in
        running) _live_col="$(printf '%brunning%b' "$GREEN"  "$NC")" ;;
        stopped) _live_col="$(printf '%bstopped%b' "$YELLOW" "$NC")" ;;
        missing) _live_col="$(printf '%bmissing%b' "$RED"    "$NC")" ;;
        *)       _live_col="$_live" ;;
    esac

    _mheader "app: $name  ($_d)"
    printf '\n'
    printf '  Status: %s  │  SSL: %s  │  CF: %s\n' "$_live_col" "$_ssl" "${_cf:-no}"
    printf '  Image:  %s\n' "$_img"
    printf '  Port:   127.0.0.1:%s → container:%s\n' "$_port" "$_intport"
    [[ -n "$_mem" ]] && printf '  Memory: %s\n' "$_mem"
    printf '  Data:   %s\n' "$_data"
    _mhr
    printf '\n'
    printf '  %b[1]%b  Info & details          %b[6]%b  Restart container\n'    "$BOLD" "$NC" "$BOLD" "$NC"
    printf '  %b[2]%b  %-7s container        %b[7]%b  SSL manage\n'             "$BOLD" "$NC" "$_toggle" "$BOLD" "$NC"
    printf '  %b[3]%b  Logs (last 100)         %b[8]%b  Recreate (re-run image)\n' "$BOLD" "$NC" "$BOLD" "$NC"
    printf '  %b[4]%b  Logs follow (-f)        %b[9]%b  Pull latest image\n'    "$BOLD" "$NC" "$BOLD" "$NC"
    printf '  %b[5]%b  Open shell in container\n' "$BOLD" "$NC"
    _mhr
    printf '  %b[B]%b  Backup app NOW          %b[R]%b  Restore from backup\n'  "$BOLD" "$NC" "$BOLD" "$NC"
    _mhr
    printf '  %b[d]%b  Delete app              %b[0]%b  Back\n' "$BOLD" "$NC" "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1) _mc; app_registry_print_info "$name"; _mpause; menu_app_detail "$name" ;;
        2)
            require_root
            if [[ "$_live" == "running" ]]; then app_stop  "$name" || true
            else                                  app_start "$name" || true
            fi
            _mpause; menu_app_detail "$name"
            ;;
        3)
            _mc
            printf '\n  Last 100 lines of %s:\n\n' "$_container"
            docker logs --tail 100 "$_container" 2>&1 | tail -100 || true
            _mpause; menu_app_detail "$name"
            ;;
        4)
            _mc
            printf '\n  Following logs for %s — press Ctrl+C to stop.\n\n' "$_container"
            docker logs -f --tail 50 "$_container" 2>&1 || true
            menu_app_detail "$name"
            ;;
        5)
            require_root
            printf '\n  %bOpening shell in %s. Type "exit" to return.%b\n\n' "$BOLD" "$_container" "$NC"
            app_shell "$name" || true
            menu_app_detail "$name"
            ;;
        6)
            require_root
            app_restart "$name" || true
            _mpause; menu_app_detail "$name"
            ;;
        7) _menu_do_ssl "$_d"; menu_app_detail "$name" ;;
        8)
            require_root
            log_info "Recreating container $_container from image $_img..."
            docker rm -f "$_container" >/dev/null 2>&1 || true
            app_start "$name" 2>/dev/null || \
                log_warn "Recreate not implemented — use: mwp app delete $name && mwp app create ..."
            _mpause; menu_app_detail "$name"
            ;;
        9)
            require_root
            _mc
            log_info "Pulling latest: $_img"
            docker pull "$_img" 2>&1 | tail -5 || true
            log_sub "Image pulled. Restart container to apply: select [6] above."
            _mpause; menu_app_detail "$name"
            ;;
        b|B|backup)
            require_root
            source "$MWP_DIR/lib/multi-app-backup.sh"
            _mc
            backup_app "$name" "full" || true
            _mpause; menu_app_detail "$name"
            ;;
        r|R|restore)
            _menu_app_restore "$name"
            menu_app_detail "$name"
            ;;
        d|delete)
            require_root
            app_delete "$name" || true
            return
            ;;
        0|back) return ;;
        *) menu_app_detail "$name" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# App restore picker — list /var/lib/mwp/app-backups/<name>/, let user
# pick one, run restore_app
# ──────────────────────────────────────────────────────────────────────

_menu_app_restore() {
    local name="$1"
    local bdir="/var/lib/mwp/app-backups/$name"

    _mc
    printf '\n  %bRestore app: %s%b\n' "$BOLD" "$name" "$NC"
    _mhr

    local -a files=()
    local f size mtime date_str idx=0
    if [[ -d "$bdir" ]]; then
        for f in "$bdir"/*.tar.gz; do
            [[ -f "$f" ]] || continue
            files+=("$f")
        done
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        printf '  %bNo backups found at %s%b\n' "$YELLOW" "$bdir" "$NC"
        printf '  Run: mwp app backup %s\n' "$name"
        _mpause; return
    fi

    # Sort newest first
    local -a sorted=()
    while IFS= read -r f; do sorted+=("$f"); done < <(printf '%s\n' "${files[@]}" | xargs -d '\n' ls -t 2>/dev/null)

    for f in "${sorted[@]}"; do
        idx=$(( idx + 1 ))
        size="$(du -h "$f" 2>/dev/null | cut -f1)"
        mtime="$(stat -c %Y "$f")"
        date_str="$(date -d "@${mtime}" '+%Y-%m-%d %H:%M' 2>/dev/null)"
        printf '  %b[%s]%b  %-50s  %-16s  %s\n' \
            "$BOLD" "$idx" "$NC" "$(basename "$f")" "$date_str" "$size"
    done

    _mhr
    printf '  %b[0]%b  Cancel\n' "$BOLD" "$NC"
    _mprompt "Pick #"

    if [[ "$MENU_INPUT" =~ ^[0-9]+$ ]] && \
       [[ $MENU_INPUT -ge 1 && $MENU_INPUT -le ${#sorted[@]} ]]; then
        local sel="${sorted[$((MENU_INPUT-1))]}"
        require_root
        source "$MWP_DIR/lib/multi-app-backup.sh"
        restore_app "$name" "$sel" || true
        _mpause
    fi
}

# ──────────────────────────────────────────────────────────────────────
# App-create wizard — collects required + optional inputs, then calls
# app_create. Refuses early if Docker isn't installed.
# ──────────────────────────────────────────────────────────────────────

_menu_app_create_wizard() {
    _menu_apps_lazy_load
    require_root

    if ! command -v docker >/dev/null 2>&1; then
        _mc
        printf '\n  %bDocker engine is not installed.%b\n' "$RED" "$NC"
        printf '  Install it first: pick [i] in the Apps menu, or run:\n'
        printf '    mwp docker install\n'
        _mpause; return
    fi

    local _name _domain _image _port _mem _env _envfile _vol _cont
    _mc
    printf '\n  %bCreate new Docker app%b\n' "$BOLD" "$NC"
    _mhr
    printf '  Examples:\n'
    printf '    name=n8n    image=docker.n8n.io/n8nio/n8n   port=5678\n'
    printf '    name=blog   image=ghost:5                    port=2368\n'
    printf '    name=api    image=ghcr.io/me/api:latest      port=8080\n'
    _mhr

    printf '  App name (lowercase, 1-32 chars, ENTER to cancel):  '
    read -r _name
    [[ -z "$_name" ]] && return

    printf '  Domain (e.g. n8n.example.com):  '
    read -r _domain
    [[ -z "$_domain" ]] && { log_warn "Cancelled."; _mpause; return; }

    printf '  Docker image (e.g. n8nio/n8n:latest):  '
    read -r _image
    [[ -z "$_image" ]] && { log_warn "Cancelled."; _mpause; return; }

    printf '  Internal port (ENTER for 3000):  '
    read -r _port
    [[ -z "$_port" ]] && _port="3000"

    printf '  Memory limit (e.g. 512m, ENTER for none):  '
    read -r _mem

    printf '\n  About to create:\n'
    printf '    Name:    %s\n' "$_name"
    printf '    Domain:  %s\n' "$_domain"
    printf '    Image:   %s\n' "$_image"
    printf '    Port:    %s\n' "$_port"
    [[ -n "$_mem" ]] && printf '    Memory:  %s\n' "$_mem"
    printf '\n  Confirm? (y/N): '
    read -r _cont
    [[ "${_cont,,}" != "y" ]] && { log_info "Cancelled."; _mpause; return; }

    _mc
    local _args=(
        "$_name"
        --domain "$_domain"
        --image  "$_image"
        --port   "$_port"
    )
    [[ -n "$_mem" ]] && _args+=( --memory "$_mem" )

    app_create "${_args[@]}" || true
    _mpause
}

# ──────────────────────────────────────────────────────────────────────
# Register external container picker
# ──────────────────────────────────────────────────────────────────────

_menu_app_register() {
    require_root
    if ! command -v docker >/dev/null 2>&1; then
        log_warn "Docker not installed — nothing to register."
        _mpause; return
    fi

    _mc
    printf '\n  %bRegister external Docker container%b\n' "$BOLD" "$NC"
    _mhr

    # Build list of containers NOT yet registered with mwp
    local -a candidates=()
    local cname
    while IFS= read -r cname; do
        [[ -z "$cname" ]] && continue
        # Skip if already in registry
        [[ -f "$MWP_APPS_DIR/${cname}.conf" ]] && continue
        candidates+=("$cname")
    done < <(docker ps --format '{{.Names}}' 2>/dev/null)

    if [[ ${#candidates[@]} -eq 0 ]]; then
        printf '  No unregistered containers running.\n'
        _mpause; return
    fi

    printf '  %b%-3s  %-32s  %s%b\n' "$BOLD" "#" "CONTAINER" "IMAGE" "$NC"
    _mhr
    local idx=0 c img
    for c in "${candidates[@]}"; do
        idx=$(( idx + 1 ))
        img="$(docker inspect "$c" --format '{{.Config.Image}}' 2>/dev/null)"
        printf '  %b%-3s%b  %-32s  %s\n' "$BOLD" "$idx" "$NC" "$c" "$img"
    done
    _mhr
    printf '  %b[0]%b  Cancel\n' "$BOLD" "$NC"
    _mprompt "Container #"

    if [[ "$MENU_INPUT" =~ ^[0-9]+$ ]] && \
       [[ $MENU_INPUT -ge 1 && $MENU_INPUT -le ${#candidates[@]} ]]; then
        local sel="${candidates[$((MENU_INPUT-1))]}"
        source "$MWP_DIR/lib/multi-app-backup.sh"
        app_register "$sel"
        _mpause
    fi
}
