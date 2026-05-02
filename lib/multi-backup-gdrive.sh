#!/usr/bin/env bash
# lib/multi-backup-gdrive.sh — focused Google Drive backup setup
#
# Why this exists separately from lib/multi-backup-remote.sh:
#   The generic `mwp backup remote setup` runs rclone's full 50-provider
#   wizard. For the very common case of "I just want to back up to my
#   Google Drive", that wizard is way too much friction. This module
#   wraps the two practical headless-friendly auth modes for Drive into
#   one focused command.
#
# Two auth modes:
#   oauth — Operator runs `rclone authorize "drive"` on a machine WITH a
#           browser (laptop), pastes the resulting JSON token here.
#           Quick (≈2 min). Token can expire after ~6 months idle.
#   sa    — Service Account JSON downloaded from Google Cloud Console.
#           Headless. Never expires. SA is a separate identity, so the
#           operator must share a Drive folder with the SA email (or use
#           a Shared Drive / Team Drive).
#
# After setup completes, BACKUP_REMOTE is set in /etc/mwp/server.conf,
# and the existing push code in lib/multi-backup-remote.sh handles
# uploads automatically after every `mwp backup full <domain>`.

[[ -n "${_MWP_BACKUP_GDRIVE_LOADED:-}" ]] && return 0
_MWP_BACKUP_GDRIVE_LOADED=1

GDRIVE_SA_DIR="/etc/mwp/gdrive-sa"

# ---------------------------------------------------------------------------
# Public entry — interactive wizard
# ---------------------------------------------------------------------------
backup_gdrive_setup() {
    require_root

    # Reuse rclone install + section-rewrite helpers from the generic lib
    [[ -n "${_MWP_BACKUP_REMOTE_LOADED:-}" ]] || \
        source "$MWP_DIR/lib/multi-backup-remote.sh"
    backup_remote_install

    printf '\n%b  Google Drive backup setup%b\n' "$BOLD" "$NC"
    printf '  %s\n' "─────────────────────────────────────────────────────"

    # 1) Remote alias (rclone section name)
    local name
    printf '  Remote alias (rclone name, default: gdrive): '
    read -r name
    name="${name:-gdrive}"
    if grep -q "^\[$name\]" /root/.config/rclone/rclone.conf 2>/dev/null; then
        log_warn "Remote '$name' already exists in rclone.conf — will be overwritten."
        printf '  Continue? (y/N): '
        local _c; read -r _c
        [[ "${_c,,}" != "y" ]] && { log_info "Cancelled."; return 0; }
        _gdrive_remove_section "$name"
    fi

    # 2) Auth method
    printf '\n  Authentication method:\n'
    printf '    %b[1]%b OAuth  — paste token from a machine with a browser  %b(quick)%b\n' \
        "$BOLD" "$NC" "$DIM" "$NC"
    printf '    %b[2]%b Service Account JSON  — fully headless              %b(production)%b\n' \
        "$BOLD" "$NC" "$DIM" "$NC"
    printf '  Choose [1]: '
    local auth
    read -r auth
    auth="${auth:-1}"

    case "$auth" in
        1) _gdrive_setup_oauth "$name" || return 1 ;;
        2) _gdrive_setup_sa    "$name" || return 1 ;;
        *) die "Invalid choice: $auth" ;;
    esac

    # 3) Folder name (the per-host subfolder is added automatically on push)
    local folder
    printf '\n  Drive folder name (default: mwp-backups): '
    read -r folder
    folder="${folder:-mwp-backups}"

    # 4) Create + validate
    log_info "Creating folder $name:$folder ..."
    if ! rclone mkdir "$name:$folder" 2>&1 | tail -3; then
        die "Cannot create folder. Check Drive permissions / network."
    fi
    if ! rclone lsd "$name:$folder" >/dev/null 2>&1; then
        die "Cannot list folder $name:$folder. Auth may have failed — check token / SA."
    fi

    # 5) Activate
    server_set "BACKUP_REMOTE" "$name:$folder"
    local hn
    hn="$(hostname -f 2>/dev/null || hostname)"
    log_success "Google Drive configured. Active target: $name:$folder"
    log_sub "Future backups upload to: $name:$folder/$hn/"
    log_sub "Verify with: mwp backup remote status"
    log_sub "Test push:   mwp backup full <domain>"
}

# ---------------------------------------------------------------------------
# OAuth — operator runs rclone authorize on a laptop, pastes token here
# ---------------------------------------------------------------------------
_gdrive_setup_oauth() {
    local name="$1"
    cat <<'OAUTHHELP'

  ─── OAuth setup (paste token from another machine) ───────────────

  On a MACHINE WITH A BROWSER  (your laptop — NOT this server):

    1. Install rclone:  https://rclone.org/install/
       (one-liner: curl https://rclone.org/install.sh | sudo bash)

    2. Run this command in the laptop terminal:

         rclone authorize "drive"

    3. A browser tab opens. Log in to the Google account that should
       OWN the backups. Click "Allow".

    4. The terminal prints a JSON token on a single line, e.g.:
         {"access_token":"ya29....","token_type":"Bearer","refresh_token":"1//0...","expiry":"..."}

    5. Copy that ENTIRE LINE (must start with { and end with }).

OAUTHHELP
    printf '  Paste the JSON token here:\n  > '
    local token
    read -r token
    token="$(printf '%s' "$token" | tr -d '\r')"
    [[ -z "$token" ]] && die "No token provided."
    [[ "$token" == "{"*"}" ]] || \
        die "Token must be a JSON object starting with { and ending with }."

    mkdir -p /root/.config/rclone
    chmod 700 /root/.config/rclone
    cat >> /root/.config/rclone/rclone.conf <<RCLONECONF

[$name]
type = drive
scope = drive
token = $token
RCLONECONF
    chmod 600 /root/.config/rclone/rclone.conf
    log_success "OAuth token saved → /root/.config/rclone/rclone.conf"
}

# ---------------------------------------------------------------------------
# Service Account — paste path to JSON downloaded from Cloud Console
# ---------------------------------------------------------------------------
_gdrive_setup_sa() {
    local name="$1"
    local our_ip
    our_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -z "$our_ip" ]] && our_ip="<this-server>"

    cat <<SAHELP

  ─── Service Account setup ────────────────────────────────────────

  1. Open  https://console.cloud.google.com/  (sign in with the Google
     account that will own the SA — does NOT need to own the Drive folder).

  2. Create a new project (or pick existing).

  3. APIs & Services → Library → search "Google Drive API" → ENABLE.

  4. APIs & Services → Credentials → Create Credentials →
     Service Account.  Give it any name (e.g. "mwp-backup").

  5. Open the new SA → KEYS tab → ADD KEY → Create new key → JSON.
     A JSON file downloads to your computer.

  6. Upload that JSON to this server, e.g. from your laptop:

       scp service-account.json root@${our_ip}:/root/

  7. Paste the path below (e.g. /root/service-account.json).

  IMPORTANT — Service Account is a separate Google identity:
    • To back up to YOUR personal Drive, share a folder with the
      SA email (visible in the JSON as "client_email"), then use
      that folder name in the next step.
    • Or create a Shared Drive / Team Drive and add the SA as a
      member with Content Manager role.

SAHELP
    printf '  Path to Service Account JSON on this server:\n  > '
    local sa_path
    read -r sa_path
    [[ -z "$sa_path" ]] && die "No path provided."
    [[ -f "$sa_path" ]] || die "File not found: $sa_path"
    grep -q '"type": *"service_account"' "$sa_path" || \
        die "$sa_path doesn't look like a valid Service Account JSON."

    mkdir -p "$GDRIVE_SA_DIR"
    chmod 700 "$GDRIVE_SA_DIR"
    local sa_dest="$GDRIVE_SA_DIR/${name}.json"
    cp "$sa_path" "$sa_dest"
    chmod 600 "$sa_dest"
    log_sub "SA copied to $sa_dest (chmod 600)"

    mkdir -p /root/.config/rclone
    chmod 700 /root/.config/rclone
    cat >> /root/.config/rclone/rclone.conf <<RCLONECONF

[$name]
type = drive
scope = drive
service_account_file = $sa_dest
RCLONECONF
    chmod 600 /root/.config/rclone/rclone.conf

    # Show SA email so operator knows what to share Drive folder with
    local sa_email
    sa_email="$(grep '"client_email"' "$sa_dest" \
                 | sed 's/.*"client_email":[[:space:]]*"\([^"]*\)".*/\1/')"
    if [[ -n "$sa_email" ]]; then
        log_success "Service Account configured."
        printf '\n  %bSA email — share your Drive folder with this address:%b\n\n' \
            "$BOLD" "$NC"
        printf '    %b%s%b\n\n' "$GREEN" "$sa_email" "$NC"
    fi
}

# ---------------------------------------------------------------------------
# Helper — remove a [<name>] section from rclone.conf (used when overwriting)
# ---------------------------------------------------------------------------
_gdrive_remove_section() {
    local name="$1"
    local conf="/root/.config/rclone/rclone.conf"
    [[ -f "$conf" ]] || return 0
    local tmp; tmp="$(mktemp)"
    awk -v section="[$name]" '
        $0 == section { skip=1; next }
        /^\[/         { skip=0 }
        !skip         { print }
    ' "$conf" > "$tmp"
    mv "$tmp" "$conf"
    chmod 600 "$conf"
}
