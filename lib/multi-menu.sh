#!/usr/bin/env bash
# lib/multi-menu.sh — Loader for the modular interactive TUI.
#
# The actual menu code lives in lib/menu/*.sh (one file per area). This
# loader exists so multi/menu.sh + lib/multi-app.sh + anything else that
# already does `source lib/multi-menu.sh` continues to work.
#
# Each module is guarded against double-source via _MWP_MENU_*_LOADED, so
# loading them all here is cheap.

[[ -n "${_MWP_MENU_LOADED:-}" ]] && return 0
_MWP_MENU_LOADED=1

# _core MUST come first — it defines primitives the others rely on.
source "$MWP_DIR/lib/menu/_core.sh"
source "$MWP_DIR/lib/menu/sites.sh"
source "$MWP_DIR/lib/menu/apps.sh"
source "$MWP_DIR/lib/menu/php.sh"
source "$MWP_DIR/lib/menu/ssl.sh"
source "$MWP_DIR/lib/menu/backup.sh"
source "$MWP_DIR/lib/menu/security.sh"
source "$MWP_DIR/lib/menu/server.sh"
source "$MWP_DIR/lib/menu/settings.sh"
source "$MWP_DIR/lib/menu/root.sh"
