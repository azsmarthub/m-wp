#!/usr/bin/env bash
# lib/menu/server.sh — Server status & FPM tuning

[[ -n "${_MWP_MENU_SERVER_LOADED:-}" ]] && return 0
_MWP_MENU_SERVER_LOADED=1

menu_server() {
    local _ip _ram _cpu _svc
    _mheader "Server Status & Tuning"
    printf '\n'
    printf '  %b[1]%b  Server status + all sites\n'  "$BOLD" "$NC"
    printf '  %b[2]%b  Retune PHP-FPM (apply)\n'     "$BOLD" "$NC"
    printf '  %b[3]%b  Retune preview (dry-run)\n'   "$BOLD" "$NC"
    printf '  %b[4]%b  Live resource usage (top -bn1)\n' "$BOLD" "$NC"
    printf '  %b[5]%b  Systemd services overview\n'  "$BOLD" "$NC"
    _mhr
    printf '  %b[0]%b  Back\n' "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1)
            _mc
            _ip="$(server_get SERVER_IP 2>/dev/null)"; [[ -z "$_ip" ]] && _ip="$(detect_ip)"
            _ram="$(detect_ram_mb)"
            _cpu="$(detect_cpu_cores)"
            printf '\n  %bServer%b\n' "$BOLD" "$NC"; _mhr
            printf '  IP:  %s\n  RAM: %sMB  │  CPU: %s cores\n' "$_ip" "$_ram" "$_cpu"
            printf '\n  %bServices%b\n' "$BOLD" "$NC"; _mhr
            for _svc in nginx mariadb redis-server fail2ban docker; do
                if systemctl list-unit-files --type=service 2>/dev/null \
                    | awk '{print $1}' | grep -q "^${_svc}\.service$"; then
                    if systemctl is-active --quiet "$_svc" 2>/dev/null; then
                        printf '  %b●%b  %-20s active\n'   "$GREEN" "$NC" "$_svc"
                    else
                        printf '  %b●%b  %-20s inactive\n' "$RED"   "$NC" "$_svc"
                    fi
                fi
            done
            _mhr
            registry_print_list
            _mpause; menu_server
            ;;
        2) _mc; require_root; tuning_retune_all; _mpause; menu_server ;;
        3) _mc; tuning_report; _mpause; menu_server ;;
        4)
            _mc
            printf '\n  %bResource snapshot (top -bn1)%b\n\n' "$BOLD" "$NC"
            top -bn1 2>/dev/null | head -25 || true
            printf '\n  %bDisk usage%b\n' "$BOLD" "$NC"
            df -h / /home /var 2>/dev/null | grep -v "^Filesystem" || df -h /
            _mpause; menu_server
            ;;
        5)
            _mc
            printf '\n  %bSystemd services (mwp-relevant)%b\n\n' "$BOLD" "$NC"
            systemctl list-units --type=service --no-pager 2>/dev/null \
                | grep -E "nginx|mariadb|redis|php|fail2ban|docker|ssh" \
                | head -30 || true
            _mpause; menu_server
            ;;
        0|b|back) menu_root ;;
        *) menu_server ;;
    esac
}
