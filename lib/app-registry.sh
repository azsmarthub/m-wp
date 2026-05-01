#!/usr/bin/env bash
# lib/app-registry.sh — App registry for mwp Docker apps
# Manages /etc/mwp/apps/<name>.conf
#
# An "app" is a Docker container fronted by an Nginx reverse proxy on a domain.
# Distinct from a "site" (WordPress, bare-metal). Sites and apps share Nginx
# but never share user / port / data dirs.

[[ -n "${_MWP_APP_REGISTRY_LOADED:-}" ]] && return 0
_MWP_APP_REGISTRY_LOADED=1

APP_PORT_MIN=10000
APP_PORT_MAX=19999

# ---------------------------------------------------------------------------
# Name validation: 1-32 chars, lowercase letters/digits/dashes, must start with letter.
# Same charset as a Docker container name suffix and a Linux username, so the
# name is reusable across `mwp-<name>` container, `app_<name>` user (if added later),
# and the registry filename.
# ---------------------------------------------------------------------------
validate_app_name() {
    local name="$1"
    [[ "$name" =~ ^[a-z][a-z0-9-]{0,31}$ ]]
}

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------
app_conf_path() {
    printf '%s/%s.conf' "$MWP_APPS_DIR" "$1"
}

app_data_dir() {
    printf '%s/%s' "$MWP_APPS_DATA_ROOT" "$1"
}

app_container_name() {
    printf 'mwp-%s' "$1"
}

# ---------------------------------------------------------------------------
# Registry CRUD
# ---------------------------------------------------------------------------
app_set() {
    local name="$1" key="$2" val="$3"
    local conf
    conf="$(app_conf_path "$name")"
    if grep -q "^${key}=" "$conf" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$conf"
    else
        printf '%s=%s\n' "$key" "$val" >> "$conf"
    fi
}

app_get() {
    local name="$1" key="$2"
    local conf
    conf="$(app_conf_path "$name")"
    grep "^${key}=" "$conf" 2>/dev/null | cut -d= -f2- || true
}

app_exists() {
    [[ -f "$(app_conf_path "$1")" ]]
}

app_count() {
    local count=0 conf
    for conf in "$MWP_APPS_DIR"/*.conf; do
        [[ -f "$conf" ]] && count=$((count + 1))
    done
    printf '%d' "$count"
}

# Search registry by domain. Echo app NAME on match, empty otherwise.
app_find_by_domain() {
    local domain="$1" conf d
    for conf in "$MWP_APPS_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        d="$(grep "^DOMAIN=" "$conf" 2>/dev/null | cut -d= -f2-)"
        if [[ "$d" == "$domain" ]]; then
            basename "$conf" .conf
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Port allocator: first free port in [APP_PORT_MIN, APP_PORT_MAX] that is
# (a) not claimed by another registered app, AND
# (b) not currently in TCP LISTEN state.
# ---------------------------------------------------------------------------
app_port_alloc() {
    local conf claimed_csv listening_csv

    # Build list of ports already claimed by other apps.
    claimed_csv=""
    for conf in "$MWP_APPS_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        local p
        p="$(grep "^HOST_PORT=" "$conf" 2>/dev/null | cut -d= -f2-)"
        [[ -n "$p" ]] && claimed_csv="${claimed_csv} ${p}"
    done

    # Build list of ports actively listening (any iface).
    # Subshell + pipefail off — closing pipe to head/awk shouldn't trip set -e.
    listening_csv="$(
        set +o pipefail
        ss -tnlH 2>/dev/null | awk '{ split($4, a, ":"); print a[length(a)] }' | tr '\n' ' '
    )"

    local port
    for (( port = APP_PORT_MIN; port <= APP_PORT_MAX; port++ )); do
        # Already claimed by an app?
        case " ${claimed_csv} " in *" ${port} "*) continue ;; esac
        # Currently listening?
        case " ${listening_csv} " in *" ${port} "*) continue ;; esac
        printf '%d' "$port"
        return 0
    done

    die "No free port in ${APP_PORT_MIN}-${APP_PORT_MAX} range — too many apps?"
}

# ---------------------------------------------------------------------------
# Register a new app. Caller must have set the env vars below before calling.
# ---------------------------------------------------------------------------
app_registry_add() {
    local name="$1"
    local conf
    conf="$(app_conf_path "$name")"
    [[ -f "$conf" ]] && die "App '$name' already registered."

    cat > "$conf" <<EOF
NAME=${name}
DOMAIN=${APP_DOMAIN}
IMAGE=${APP_IMAGE}
INTERNAL_PORT=${APP_INTERNAL_PORT}
HOST_PORT=${APP_HOST_PORT}
MEMORY_LIMIT=${APP_MEMORY_LIMIT:-}
DATA_DIR=${APP_DATA_DIR}
CONTAINER=${APP_CONTAINER}
RUNTIME=docker
SOURCE_TYPE=image
STATUS=running
CREATED_AT=$(date '+%Y-%m-%d %H:%M:%S')
EOF
    chmod 600 "$conf"
    log_success "App '$name' registered."
}

app_registry_remove() {
    local name="$1"
    local conf
    conf="$(app_conf_path "$name")"
    [[ -f "$conf" ]] || die "App '$name' not in registry."
    rm -f "$conf"
    log_info "App '$name' removed from registry."
}

# ---------------------------------------------------------------------------
# Pretty-print all apps
# ---------------------------------------------------------------------------
app_registry_print_list() {
    local count=0 conf

    printf '\n%b%-20s %-30s %-10s %-7s %s%b\n' "$BOLD" \
        "NAME" "DOMAIN" "STATUS" "PORT" "IMAGE" "$NC"
    printf '%s\n' "──────────────────────────────────────────────────────────────────────────────"

    for conf in "$MWP_APPS_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        local name domain status port image
        name="$(basename "$conf" .conf)"
        domain="$(grep "^DOMAIN="    "$conf" | cut -d= -f2-)"
        status="$(grep "^STATUS="    "$conf" | cut -d= -f2-)"
        port="$(grep "^HOST_PORT="   "$conf" | cut -d= -f2-)"
        image="$(grep "^IMAGE="      "$conf" | cut -d= -f2-)"

        # Live status: query docker
        local container live="?"
        container="$(grep "^CONTAINER=" "$conf" | cut -d= -f2-)"
        if command -v docker >/dev/null 2>&1 && [[ -n "$container" ]]; then
            if docker ps --filter "name=^${container}$" --format '{{.Names}}' 2>/dev/null | grep -q .; then
                live="running"
            elif docker ps -a --filter "name=^${container}$" --format '{{.Names}}' 2>/dev/null | grep -q .; then
                live="stopped"
            else
                live="missing"
            fi
        fi

        local color="$GREEN"
        case "$live" in
            running) color="$GREEN" ;;
            stopped) color="$YELLOW" ;;
            missing) color="$RED" ;;
        esac

        printf '%-20s %-30s %b%-10s%b %-7s %s\n' \
            "$name" "$domain" "$color" "$live" "$NC" "$port" "$image"
        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        printf '%bNo apps yet. Run: mwp app create <name> --domain D --image IMG --port P%b\n' \
            "$DIM" "$NC"
    else
        printf '\n%b%d app(s) total%b\n' "$DIM" "$count" "$NC"
    fi
    printf '\n'
}

# ---------------------------------------------------------------------------
# Pretty-print single app (config + live container info)
# ---------------------------------------------------------------------------
app_registry_print_info() {
    local name="$1"
    app_exists "$name" || die "App '$name' not found."
    local conf
    conf="$(app_conf_path "$name")"

    printf '\n%b  App: %s%b\n' "$BOLD" "$name" "$NC"
    printf '  %s\n' "──────────────────────────────────────────"
    while IFS='=' read -r key val; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        printf '  %-18s %s\n' "$key" "$val"
    done < "$conf"

    if command -v docker >/dev/null 2>&1; then
        local container
        container="$(app_get "$name" CONTAINER)"
        if [[ -n "$container" ]] && docker ps -a --filter "name=^${container}$" --format '{{.Status}}' 2>/dev/null | grep -q .; then
            printf '\n  %bContainer:%b\n' "$BOLD" "$NC"
            docker ps -a --filter "name=^${container}$" \
                --format '  Status:    {{.Status}}\n  Ports:     {{.Ports}}\n  Image:     {{.Image}}' 2>/dev/null
        fi
    fi
    printf '\n'
}
