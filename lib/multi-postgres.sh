#!/usr/bin/env bash
# lib/multi-postgres.sh — PostgreSQL install + tune + per-app DB CRUD for mwp
#
# Opt-in. Default install.sh does NOT pull this in.
# Trigger:
#   - install time:  MWP_INSTALL_POSTGRES=1 ./multi/install.sh
#   - any time:      mwp pg install
#
# Architecture:
#   - Ubuntu's stock postgresql-16 package (24.04 LTS default)
#   - listen_addresses = '*' but pg_hba.conf locks down to localhost +
#     Docker bridge (172.16.0.0/12) — UFW blocks 5432 from outside
#   - per-app DB credentials saved to /etc/mwp/pg-dbs/<name>.conf (mode 600)
#   - tuning written to /etc/postgresql/<ver>/main/conf.d/99-mwp.conf

[[ -n "${_MWP_POSTGRES_LOADED:-}" ]] && return 0
_MWP_POSTGRES_LOADED=1

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
PG_DBS_DIR="/etc/mwp/pg-dbs"
PG_HBA_BEGIN="# BEGIN MWP — managed block, do not edit by hand"
PG_HBA_END="# END MWP"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
_pg_version() {
    # Detect installed major version (16, 15, ...). Empty if not installed.
    local v
    v="$(server_get "POSTGRES_VERSION" 2>/dev/null)"
    if [[ -z "$v" ]]; then
        # Fall back to filesystem detection
        v="$(ls -1 /etc/postgresql/ 2>/dev/null | sort -rn | head -1)"
    fi
    printf '%s' "$v"
}

_pg_conf_dir() {
    local v
    v="$(_pg_version)"
    [[ -z "$v" ]] && return 1
    printf '/etc/postgresql/%s/main' "$v"
}

_pg_is_installed() {
    [[ "$(server_get "POSTGRES_INSTALLED")" == "yes" ]]
}

_pg_require_installed() {
    _pg_is_installed || die "PostgreSQL not installed. Run: mwp pg install"
}

# Run psql as the postgres OS user (peer auth, no password needed)
_pg_psql() {
    sudo -u postgres psql -t -A -c "$@" 2>&1
}

_pg_psql_quiet() {
    sudo -u postgres psql -q -c "$@" >/dev/null 2>&1
}

# Validate identifier (DB / user name) — alphanumeric + underscore, 1..63 chars
_pg_validate_ident() {
    local name="$1"
    [[ "$name" =~ ^[a-z][a-z0-9_]{0,62}$ ]] && return 0
    return 1
}

_pg_db_conf() {
    printf '%s/%s.conf' "$PG_DBS_DIR" "$1"
}

# ---------------------------------------------------------------------------
# Tuning calculator (pure bash — no external deps)
# ---------------------------------------------------------------------------
_pg_calc_tune() {
    local ram_mb cpu shared eff_cache work maint maxconn parallel
    ram_mb="$(detect_ram_mb)"
    cpu="$(detect_cpu_cores)"
    [[ -z "$ram_mb" || $ram_mb -lt 256 ]] && ram_mb=512
    [[ -z "$cpu"   || $cpu -lt 1 ]]      && cpu=1

    shared=$(( ram_mb / 4 ))                 # 25%
    eff_cache=$(( ram_mb * 3 / 4 ))          # 75%
    maxconn=50

    # work_mem — divide remaining RAM across connections, halve for safety
    work=$(( (ram_mb - shared) / maxconn / 2 ))
    [[ $work -gt 64 ]] && work=64            # cap 64MB per op
    [[ $work -lt 4 ]]  && work=4

    maint=$(( ram_mb / 16 ))
    [[ $maint -gt 2048 ]] && maint=2048
    [[ $maint -lt 64 ]]   && maint=64

    parallel=$(( cpu / 2 ))
    [[ $parallel -lt 1 ]] && parallel=1
    [[ $parallel -gt 4 ]] && parallel=4

    export RAM_MB="$ram_mb"
    export CPU_CORES="$cpu"
    export SHARED_BUFFERS_MB="$shared"
    export EFFECTIVE_CACHE_MB="$eff_cache"
    export WORK_MEM_MB="$work"
    export MAINT_WORK_MEM_MB="$maint"
    export MAX_CONNECTIONS="$maxconn"
    export PARALLEL_GATHER="$parallel"
}

# ---------------------------------------------------------------------------
# postgres_install — apt + initial setup + tune
# ---------------------------------------------------------------------------
postgres_install() {
    require_root

    if _pg_is_installed; then
        log_info "PostgreSQL already installed — refreshing tune only. To reinstall: mwp pg uninstall first."
        postgres_tune
        return 0
    fi

    log_info "Installing PostgreSQL..."
    if ! command -v psql >/dev/null 2>&1; then
        apt_install postgresql postgresql-contrib
    fi
    systemctl enable postgresql

    local pg_ver
    pg_ver="$(ls -1 /etc/postgresql/ 2>/dev/null | sort -rn | head -1)"
    [[ -z "$pg_ver" ]] && die "PostgreSQL installed but /etc/postgresql/ has no cluster — apt may have failed silently."
    log_sub "Detected PostgreSQL version: $pg_ver"

    server_set "POSTGRES_INSTALLED" "yes"
    server_set "POSTGRES_VERSION" "$pg_ver"
    server_set "POSTGRES_INSTALLED_AT" "$(date '+%Y-%m-%d %H:%M:%S')"

    mkdir -p "$PG_DBS_DIR"
    chmod 700 "$PG_DBS_DIR"

    postgres_apply_pg_hba
    postgres_apply_firewall
    postgres_tune

    log_success "PostgreSQL ${pg_ver} installed."
    printf '\n  %bCreate an app DB:%b\n' "$BOLD" "$NC"
    printf '    mwp pg db create myapp\n\n'
}

# ---------------------------------------------------------------------------
# postgres_apply_firewall — UFW rules for Docker bridge → 5432
# Public 5432 stays blocked by UFW default deny.
# ---------------------------------------------------------------------------
postgres_apply_firewall() {
    require_root
    if ! command -v ufw >/dev/null 2>&1; then
        log_sub "UFW not installed — skipping firewall rules"
        return 0
    fi
    # Allow standard Docker bridge ranges to reach 5432. UFW will silently
    # noop if the rule already exists.
    ufw allow from 172.16.0.0/12 to any port 5432 proto tcp comment "mwp pg: docker bridge" >/dev/null 2>&1 || true
    ufw allow from 127.0.0.0/8   to any port 5432 proto tcp comment "mwp pg: localhost" >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
    log_sub "UFW: 5432 allowed from 172.16.0.0/12 + 127.0.0.0/8 (public still blocked)"
}

# ---------------------------------------------------------------------------
# postgres_apply_pg_hba — manage MWP block in pg_hba.conf
# Allows: peer for postgres, scram-sha-256 from localhost + Docker bridges.
# ---------------------------------------------------------------------------
postgres_apply_pg_hba() {
    require_root
    _pg_require_installed
    local hba
    hba="$(_pg_conf_dir)/pg_hba.conf"
    [[ -f "$hba" ]] || die "pg_hba.conf not found at $hba"

    # Strip any existing MWP block
    sed -i "/^${PG_HBA_BEGIN}\$/,/^${PG_HBA_END}\$/d" "$hba"

    cat >> "$hba" <<HBA
${PG_HBA_BEGIN}
# Docker bridge networks — required for mwp app containers to reach postgres
host    all             all             172.16.0.0/12           scram-sha-256
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
${PG_HBA_END}
HBA
    systemctl reload postgresql 2>/dev/null || systemctl restart postgresql
    log_sub "pg_hba.conf updated (Docker bridge + localhost allowed via scram-sha-256)"
}

# ---------------------------------------------------------------------------
# postgres_tune — recalculate + apply tuning conf
# ---------------------------------------------------------------------------
postgres_tune() {
    require_root
    _pg_require_installed
    local pg_ver conf_d tune_file
    pg_ver="$(_pg_version)"
    conf_d="/etc/postgresql/${pg_ver}/main/conf.d"
    tune_file="${conf_d}/99-mwp.conf"

    mkdir -p "$conf_d"
    _pg_calc_tune
    GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S')" \
    PG_VERSION="$pg_ver" \
        render_template "$MWP_DIR/templates/postgres/postgresql-tune.conf.tpl" > "$tune_file"
    chmod 644 "$tune_file"

    # shared_buffers + max_connections need restart, not reload
    systemctl restart postgresql || die "postgresql failed to restart with new tune — check journalctl -u postgresql"

    log_success "PostgreSQL tuned."
    printf '  RAM:               %sMB → shared_buffers=%sMB, effective_cache=%sMB\n' \
        "$RAM_MB" "$SHARED_BUFFERS_MB" "$EFFECTIVE_CACHE_MB"
    printf '  Connections:       max=%s, work_mem=%sMB, maintenance=%sMB\n' \
        "$MAX_CONNECTIONS" "$WORK_MEM_MB" "$MAINT_WORK_MEM_MB"
    printf '  Parallelism:       %s cores → parallel_workers_per_gather=%s\n\n' \
        "$CPU_CORES" "$PARALLEL_GATHER"
}

# ---------------------------------------------------------------------------
# postgres_status — install state + live metrics
# ---------------------------------------------------------------------------
postgres_status() {
    printf '\n%b  PostgreSQL status%b\n' "$BOLD" "$NC"
    printf '  %s\n' "──────────────────────────────────"

    if ! _pg_is_installed; then
        printf '  Installed:  %bno%b\n' "$YELLOW" "$NC"
        printf '  Install:    mwp pg install\n\n'
        return 0
    fi

    local pg_ver svc_state installed_at
    pg_ver="$(_pg_version)"
    svc_state="inactive"
    systemctl is-active --quiet postgresql 2>/dev/null && svc_state="active"
    installed_at="$(server_get "POSTGRES_INSTALLED_AT")"

    printf '  Installed:    %byes%b  (%s)\n' "$GREEN" "$NC" "$installed_at"
    printf '  Version:      %s\n' "$pg_ver"
    printf '  Service:      %s\n' "$svc_state"

    if [[ "$svc_state" == "active" ]]; then
        local conn_count db_count size
        conn_count="$(_pg_psql 'SELECT count(*) FROM pg_stat_activity' 2>/dev/null | tr -d '[:space:]')"
        db_count="$(_pg_psql "SELECT count(*) FROM pg_database WHERE datistemplate=false AND datname NOT IN ('postgres')" 2>/dev/null | tr -d '[:space:]')"
        size="$(_pg_psql "SELECT pg_size_pretty(sum(pg_database_size(datname))) FROM pg_database WHERE datistemplate=false" 2>/dev/null | tr -d '[:space:]')"
        printf '  Active conns: %s\n' "${conn_count:-0}"
        printf '  User DBs:     %s\n' "${db_count:-0}"
        printf '  Total size:   %s\n' "${size:-0 bytes}"
    fi

    # Tuning summary
    local tune_file
    tune_file="$(_pg_conf_dir)/conf.d/99-mwp.conf"
    if [[ -f "$tune_file" ]]; then
        local sb mc
        sb="$(grep ^shared_buffers "$tune_file" | head -1 | awk -F'=' '{print $2}' | awk '{print $1}')"
        mc="$(grep ^max_connections "$tune_file" | head -1 | awk -F'=' '{print $2}' | awk '{print $1}')"
        printf '  Tuning:       shared_buffers=%s, max_connections=%s\n' "$sb" "$mc"
    fi

    printf '\n  Manage DBs:  mwp pg db list\n'
    printf '  Re-tune:     mwp pg tune\n\n'
}

# ---------------------------------------------------------------------------
# postgres_db_create <name> [user]
# Creates DB owned by user (auto-creates user with random password).
# Saves credentials to /etc/mwp/pg-dbs/<name>.conf for app reference.
# ---------------------------------------------------------------------------
postgres_db_create() {
    require_root
    local name="${1:-}"
    local user="${2:-$name}"
    [[ -z "$name" ]] && die "Usage: mwp pg db create <name> [user]"
    _pg_validate_ident "$name" || die "DB name must be lowercase alphanumeric+underscore, start with letter, max 63 chars"
    _pg_validate_ident "$user" || die "User name must be lowercase alphanumeric+underscore, start with letter, max 63 chars"
    _pg_require_installed

    local conf
    conf="$(_pg_db_conf "$name")"
    [[ -f "$conf" ]] && die "DB '$name' already managed by mwp (see $conf). Drop first: mwp pg db drop $name"

    # Check if DB / user exist outside mwp's view
    local exists
    exists="$(_pg_psql "SELECT 1 FROM pg_database WHERE datname='${name}'" | tr -d '[:space:]')"
    [[ "$exists" == "1" ]] && die "PostgreSQL DB '$name' already exists (not managed by mwp). Drop manually first."

    local user_exists
    user_exists="$(_pg_psql "SELECT 1 FROM pg_roles WHERE rolname='${user}'" | tr -d '[:space:]')"

    local password
    password="$(generate_password 24)"

    if [[ "$user_exists" != "1" ]]; then
        _pg_psql_quiet "CREATE USER \"${user}\" WITH PASSWORD '${password}';" \
            || die "Failed to create user '$user'"
        log_sub "User created: $user"
    else
        # Existing user — reset password
        _pg_psql_quiet "ALTER USER \"${user}\" WITH PASSWORD '${password}';" \
            || die "Failed to reset password for user '$user'"
        log_sub "User exists — password reset"
    fi

    _pg_psql_quiet "CREATE DATABASE \"${name}\" OWNER \"${user}\";" \
        || { _pg_psql_quiet "DROP USER IF EXISTS \"${user}\";"; die "Failed to create DB '$name'"; }

    # Default privileges so the user can do everything in their own DB
    _pg_psql_quiet "GRANT ALL PRIVILEGES ON DATABASE \"${name}\" TO \"${user}\";"
    # PG 15+: must grant CREATE on public schema explicitly
    _pg_psql_quiet "ALTER DATABASE \"${name}\" OWNER TO \"${user}\";"

    # Quote CREATED_AT — value contains a space, so an unquoted assignment
    # would crash any caller that `source`s the file (bash splits on space).
    cat > "$conf" <<EOF
DB_NAME=${name}
DB_USER=${user}
DB_PASS=${password}
HOST=localhost
PORT=5432
CREATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    chmod 600 "$conf"

    local server_ip docker_ip
    server_ip="$(detect_ip)"
    docker_ip="$(ip -4 addr show docker0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)"

    printf '\n%b  PostgreSQL DB created%b\n' "$GREEN" "$NC"
    printf '  %s\n' "──────────────────────────────────────────────────────────"
    printf '  DB:          %s\n' "$name"
    printf '  User:        %s\n' "$user"
    printf '  Password:    %b%s%b\n' "$BOLD" "$password" "$NC"
    printf '\n  %bConnection strings:%b\n' "$BOLD" "$NC"
    printf '    From host:        postgresql://%s:%s@localhost:5432/%s\n' "$user" "$password" "$name"
    [[ -n "$docker_ip" ]] && \
        printf '    From Docker app:  postgresql://%s:%s@%s:5432/%s\n' "$user" "$password" "$docker_ip" "$name"
    printf '    JDBC:             jdbc:postgresql://localhost:5432/%s\n' "$name"
    printf '\n  Saved to:    %s\n\n' "$conf"
}

# ---------------------------------------------------------------------------
# postgres_db_drop <name>
# ---------------------------------------------------------------------------
postgres_db_drop() {
    require_root
    local name="${1:-}"
    [[ -z "$name" ]] && die "Usage: mwp pg db drop <name>"
    _pg_validate_ident "$name" || die "Invalid name"
    _pg_require_installed

    local conf user
    conf="$(_pg_db_conf "$name")"
    if [[ -f "$conf" ]]; then
        # shellcheck source=/dev/null
        source "$conf"
        user="$DB_USER"
    fi

    confirm "Drop DB '$name' (and user '${user:-?}') — irreversible. Continue?" \
        || { log_info "Aborted."; return 0; }

    # Terminate any active sessions on this DB so DROP doesn't block
    _pg_psql_quiet "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${name}' AND pid<>pg_backend_pid();"
    _pg_psql_quiet "DROP DATABASE IF EXISTS \"${name}\";"
    [[ -n "${user:-}" ]] && _pg_psql_quiet "DROP USER IF EXISTS \"${user}\";"
    rm -f "$conf"

    log_success "DB '$name' dropped."
}

# ---------------------------------------------------------------------------
# postgres_db_list — show all mwp-managed DBs + a few stats
# ---------------------------------------------------------------------------
postgres_db_list() {
    _pg_require_installed
    printf '\n%b  PostgreSQL DBs (mwp-managed)%b\n' "$BOLD" "$NC"
    printf '  %s\n' "─────────────────────────────────────────────────────────────────"
    printf '  %-24s %-24s %-10s %s\n' "DB" "USER" "SIZE" "CREATED"
    printf '  %s\n' "─────────────────────────────────────────────────────────────────"

    local count=0 conf db user created size
    for conf in "$PG_DBS_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        # shellcheck source=/dev/null
        source "$conf"
        db="$DB_NAME"
        user="$DB_USER"
        created="$CREATED_AT"
        size="$(_pg_psql "SELECT pg_size_pretty(pg_database_size('${db}'))" 2>/dev/null | tr -d '[:space:]')"
        [[ -z "$size" ]] && size="missing"
        printf '  %-24s %-24s %-10s %s\n' \
            "$(_trunc "$db" 24)" "$(_trunc "$user" 24)" "$size" "$created"
        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        printf '  %bNo DBs yet. Create: mwp pg db create <name>%b\n' "$DIM" "$NC"
    else
        printf '\n  %b%d DB(s) total%b\n' "$DIM" "$count" "$NC"
    fi
    printf '\n'
}

postgres_db_info() {
    require_root
    local name="${1:-}"
    [[ -z "$name" ]] && die "Usage: mwp pg db info <name>"
    local conf
    conf="$(_pg_db_conf "$name")"
    [[ -f "$conf" ]] || die "DB '$name' not managed by mwp."
    printf '\n%b  DB: %s%b\n' "$BOLD" "$name" "$NC"
    printf '  %s\n' "──────────────────────────────────"
    while IFS='=' read -r k v; do
        [[ -z "$k" || "$k" == \#* ]] && continue
        [[ "$k" == "DB_PASS" ]] && v="***  (cat $conf to see)"
        printf '  %-12s %s\n' "$k" "$v"
    done < "$conf"
    printf '\n'
}

# ---------------------------------------------------------------------------
# postgres_uninstall — full removal
# ---------------------------------------------------------------------------
postgres_uninstall() {
    require_root
    if ! _pg_is_installed; then
        log_info "PostgreSQL is not installed."
        return 0
    fi

    confirm "Uninstall PostgreSQL — drops all DBs + cluster data. IRREVERSIBLE. Continue?" \
        || { log_info "Aborted."; return 0; }

    apt_wait
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -q postgresql\* >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -q >/dev/null 2>&1 || true
    rm -rf /etc/postgresql /var/lib/postgresql "$PG_DBS_DIR"

    sed -i '/^POSTGRES_INSTALLED=/d;/^POSTGRES_VERSION=/d;/^POSTGRES_INSTALLED_AT=/d' \
        "$MWP_SERVER_CONF" 2>/dev/null || true

    log_success "PostgreSQL removed."
}

# ---------------------------------------------------------------------------
# postgres_psql — drop into psql as postgres superuser
# ---------------------------------------------------------------------------
postgres_psql() {
    require_root
    _pg_require_installed
    exec sudo -iu postgres psql
}
