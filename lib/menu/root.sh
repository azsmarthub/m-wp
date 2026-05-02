#!/usr/bin/env bash
# lib/menu/root.sh — Top-level (Level 0) menu
#
# New ordering (v0.5.0):
#   [1] Sites & Apps          (unified — WP, Laravel, Docker, External)
#   [2] Server status         (was [5] — bumped up since checked frequently)
#   [3] Docker apps           (engine + create wizard + container actions)
#   [4] SSL certificates
#   [5] Backups & Restore     (incl. offsite via rclone)
#   [6] Security              (SSH harden + CF + isolation audit)
#   [7] PHP versions          (was [2] — bumped down since rarely changed)
#   [8] Settings

[[ -n "${_MWP_MENU_ROOT_LOADED:-}" ]] && return 0
_MWP_MENU_ROOT_LOADED=1

menu_root() {
    _mheader
    printf '\n'
    printf '  %b[1]%b  Sites & Apps          (WordPress + Laravel + Docker + external)\n' "$BOLD" "$NC"
    printf '  %b[2]%b  Server status & tuning\n'                                          "$BOLD" "$NC"
    printf '  %b[3]%b  Docker apps           (Docker-specific create / manage)\n'         "$BOLD" "$NC"
    printf '  %b[4]%b  SSL certificates\n'                                                "$BOLD" "$NC"
    printf '  %b[5]%b  Backups & Restore     (local + offsite rclone)\n'                  "$BOLD" "$NC"
    printf '  %b[6]%b  Security              (SSH / Cloudflare / isolation audit)\n'      "$BOLD" "$NC"
    printf '  %b[7]%b  PHP versions\n'                                                    "$BOLD" "$NC"
    printf '  %b[8]%b  Settings              (panel domain, default PHP)\n'               "$BOLD" "$NC"
    _mhr
    printf '  %b[0]%b  Exit\n' "$BOLD" "$NC"
    _mprompt

    case "$MENU_INPUT" in
        1) _load_site_libs; menu_sites    ;;
        2) _load_site_libs; menu_server   ;;
        3) _load_site_libs; menu_apps     ;;
        4) _load_site_libs; menu_ssl_list ;;
        5) _load_site_libs; menu_backup   ;;
        6) _load_site_libs; menu_security ;;
        7) _load_site_libs; menu_php      ;;
        8)                  menu_settings ;;
        0|q|exit) printf '\n'; exit 0 ;;
        *) menu_root ;;
    esac
}
