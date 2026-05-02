#!/usr/bin/env bash
# lib/multi-backup-schedule.sh — Scheduled backups via systemd timers
#
# Why systemd timers (not cron):
#   - Native to Ubuntu 24.04, no extra package
#   - `systemctl status mwp-backup.timer` shows next run + last result
#   - journalctl -u mwp-backup gives timestamped logs
#   - RandomizedDelaySec spreads load when multiple boxes share the schedule
#   - Persistent=true catches missed runs (server was off)
#
# Public:
#   backup_schedule_list_presets   List available presets + their cron eq.
#   backup_schedule_set <preset>   Install timer + service for the preset
#   backup_schedule_set custom <OnCalendar-spec>
#   backup_schedule_disable        Stop + remove timer
#   backup_schedule_status         Current schedule, next run, last run
#   backup_schedule_run_now        Trigger an immediate scheduled-style run
#
# Preset → OnCalendar mapping (UTC):
#   daily          *-*-* 02:00:00              every day @ 02:00
#   every-2-days   Mon,Wed,Fri,Sun *-*-* 02:00 4 days/week, ~every 2 days
#   twice-weekly   Mon,Thu *-*-* 02:00         Mon + Thu @ 02:00
#   weekly         Sun *-*-* 03:00             Sunday @ 03:00 only
#   custom         <user-supplied OnCalendar>

[[ -n "${_MWP_BACKUP_SCHEDULE_LOADED:-}" ]] && return 0
_MWP_BACKUP_SCHEDULE_LOADED=1

SCHEDULE_TIMER_UNIT="/etc/systemd/system/mwp-backup.timer"
SCHEDULE_SERVICE_UNIT="/etc/systemd/system/mwp-backup.service"
SCHEDULE_LOG="/var/log/mwp/backup-cron.log"

# ---------------------------------------------------------------------------
# Preset → OnCalendar lookup. Echoes the OnCalendar= line for the given
# preset, or empty string if unknown.
# ---------------------------------------------------------------------------
_schedule_preset_to_calendar() {
    case "$1" in
        daily)        printf '*-*-* 02:00:00' ;;
        every-2-days) printf 'Mon,Wed,Fri,Sun *-*-* 02:00:00' ;;
        twice-weekly) printf 'Mon,Thu *-*-* 02:00:00' ;;
        weekly)       printf 'Sun *-*-* 03:00:00' ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Public — list presets in a readable form
# ---------------------------------------------------------------------------
backup_schedule_list_presets() {
    printf '\n%b  Available schedule presets%b\n' "$BOLD" "$NC"
    printf '  %s\n' "─────────────────────────────────────────────────────────────"
    printf '  %b%-16s%b  %s\n' "$BOLD" "PRESET" "$NC" "WHEN (UTC)"
    printf '  %s\n' "─────────────────────────────────────────────────────────────"
    printf '  %-16s  %s\n' "daily"        "every day at 02:00"
    printf '  %-16s  %s  %b(recommended — lighter load)%b\n' \
        "every-2-days" "Mon, Wed, Fri, Sun at 02:00" "$DIM" "$NC"
    printf '  %-16s  %s\n' "twice-weekly" "Mon, Thu at 02:00"
    printf '  %-16s  %s\n' "weekly"       "Sunday at 03:00"
    printf '  %-16s  %s\n' "custom"       "<your OnCalendar spec>"
    printf '\n  Tier (auto-decided per run):\n'
    printf '    1st of month → %bmonthly%b   |   Sunday → %bweekly%b   |   else → %bdaily%b\n' \
        "$BOLD" "$NC" "$BOLD" "$NC" "$BOLD" "$NC"
    printf '\n  Apply with: %bmwp backup schedule set <preset>%b\n\n' "$BOLD" "$NC"
}

# ---------------------------------------------------------------------------
# Public — install / replace timer for the given preset
# ---------------------------------------------------------------------------
backup_schedule_set() {
    require_root
    local preset="${1:-}"
    local custom_spec="${2:-}"
    [[ -z "$preset" ]] && die "Usage: mwp backup schedule set <preset> [custom-OnCalendar]
   Run 'mwp backup schedule list' to see presets."

    local on_calendar
    if [[ "$preset" == "custom" ]]; then
        [[ -z "$custom_spec" ]] && die "Custom requires an OnCalendar spec, e.g. 'Mon..Fri *-*-* 03:00:00'"
        on_calendar="$custom_spec"
    else
        on_calendar="$(_schedule_preset_to_calendar "$preset")" \
            || die "Unknown preset: $preset (run 'mwp backup schedule list')"
    fi

    log_info "Installing schedule: $preset → $on_calendar"
    _schedule_write_units "$on_calendar"

    systemctl daemon-reload
    systemctl enable --now mwp-backup.timer >/dev/null 2>&1 \
        || die "Failed to enable mwp-backup.timer"

    server_set "BACKUP_SCHEDULE" "$preset"
    server_set "BACKUP_SCHEDULE_AT" "$(date '+%Y-%m-%d %H:%M:%S')"
    [[ "$preset" == "custom" ]] && server_set "BACKUP_SCHEDULE_CUSTOM" "$custom_spec"

    log_success "Backup schedule active: $preset"
    log_sub "Next run: $(systemctl show -p NextElapseUSecRealtime --value mwp-backup.timer 2>/dev/null \
                          | head -1)"
    log_sub "View status: mwp backup schedule status"
}

# ---------------------------------------------------------------------------
# Public — stop + remove timer
# ---------------------------------------------------------------------------
backup_schedule_disable() {
    require_root
    log_info "Disabling backup schedule..."
    systemctl disable --now mwp-backup.timer >/dev/null 2>&1 || true
    rm -f "$SCHEDULE_TIMER_UNIT" "$SCHEDULE_SERVICE_UNIT"
    systemctl daemon-reload
    server_set "BACKUP_SCHEDULE" ""
    log_success "Backup schedule disabled."
}

# ---------------------------------------------------------------------------
# Public — show current state
# ---------------------------------------------------------------------------
backup_schedule_status() {
    local sched
    sched="$(server_get BACKUP_SCHEDULE 2>/dev/null || true)"

    printf '\n%b  Backup schedule%b\n' "$BOLD" "$NC"
    printf '  %s\n' "──────────────────────────────────────────────────────────"

    if [[ -z "$sched" ]]; then
        printf '  Status:       %bnot configured%b\n' "$YELLOW" "$NC"
        printf '  %bRun:%b       mwp backup schedule list  → pick a preset\n' "$DIM" "$NC"
        printf '\n'
        return
    fi

    printf '  Preset:       %s\n' "$sched"
    [[ "$sched" == "custom" ]] && \
        printf '  OnCalendar:   %s\n' "$(server_get BACKUP_SCHEDULE_CUSTOM)"

    if systemctl is-active --quiet mwp-backup.timer 2>/dev/null; then
        printf '  Timer:        %bactive%b\n' "$GREEN" "$NC"
    else
        printf '  Timer:        %binactive%b (configured but not running)\n' "$RED" "$NC"
    fi

    # Next run + last run via systemctl (oneliner each)
    local next last
    next="$(systemctl list-timers --all 2>/dev/null \
            | awk '/mwp-backup.timer/ {print $1, $2; exit}')"
    [[ -n "$next" ]] && printf '  Next run:     %s\n' "$next"

    last="$(systemctl show -p LastTriggerUSec --value mwp-backup.timer 2>/dev/null)"
    [[ -n "$last" && "$last" != "n/a" ]] && printf '  Last run:     %s\n' "$last"

    # Show retention setup
    local kd kw km
    kd="$(server_get BACKUP_KEEP_DAILY 2>/dev/null   || true)"; kd="${kd:-7}"
    kw="$(server_get BACKUP_KEEP_WEEKLY 2>/dev/null  || true)"; kw="${kw:-4}"
    km="$(server_get BACKUP_KEEP_MONTHLY 2>/dev/null || true)"; km="${km:-12}"
    printf '  Retention:    daily=%s, weekly=%s, monthly=%s\n' "$kd" "$kw" "$km"
    printf '  Log:          %s\n' "$SCHEDULE_LOG"
    printf '\n'
}

# ---------------------------------------------------------------------------
# Public — fire an immediate run as if the timer just ticked
# ---------------------------------------------------------------------------
backup_schedule_run_now() {
    require_root
    if [[ ! -f "$SCHEDULE_SERVICE_UNIT" ]]; then
        die "Schedule not configured. Run: mwp backup schedule list"
    fi
    log_info "Triggering scheduled backup now (background) — tail logs at:"
    log_sub  "  journalctl -u mwp-backup -f"
    log_sub  "  tail -f $SCHEDULE_LOG"
    systemctl start mwp-backup.service
    log_success "Started mwp-backup.service"
}

# ---------------------------------------------------------------------------
# Internal — write the .timer + .service units
# ---------------------------------------------------------------------------
_schedule_write_units() {
    local on_calendar="$1"
    local mwp_bin="/usr/local/bin/mwp"
    [[ -x "$mwp_bin" ]] || mwp_bin="$MWP_DIR/multi/menu.sh"

    mkdir -p "$(dirname "$SCHEDULE_LOG")"
    touch "$SCHEDULE_LOG"
    chmod 644 "$SCHEDULE_LOG"

    cat > "$SCHEDULE_SERVICE_UNIT" <<SERVICE
[Unit]
Description=mwp scheduled backup (all sites)
Documentation=https://github.com/azsmarthub/m-wp
After=network-online.target nginx.service mariadb.service
Wants=network-online.target

[Service]
Type=oneshot
# Run as root (mwp needs to dump DBs + chown across users).
ExecStart=$mwp_bin backup schedule run-internal
StandardOutput=append:$SCHEDULE_LOG
StandardError=append:$SCHEDULE_LOG
# Be nice — backups shouldn't starve serving traffic.
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
# Don't run forever if something hangs (cap at 6 hours).
TimeoutStartSec=6h

[Install]
WantedBy=multi-user.target
SERVICE

    cat > "$SCHEDULE_TIMER_UNIT" <<TIMER
[Unit]
Description=mwp scheduled backup timer
Documentation=https://github.com/azsmarthub/m-wp

[Timer]
OnCalendar=$on_calendar
# Run on next boot if a scheduled run was missed (server was off).
Persistent=true
# Spread load up to 10 min so multiple VPS sharing offsite don't race.
RandomizedDelaySec=10min
Unit=mwp-backup.service

[Install]
WantedBy=timers.target
TIMER
    chmod 644 "$SCHEDULE_TIMER_UNIT" "$SCHEDULE_SERVICE_UNIT"
    log_sub "Wrote: $SCHEDULE_TIMER_UNIT"
    log_sub "Wrote: $SCHEDULE_SERVICE_UNIT"
}
