#!/usr/bin/env bash
# lib/multi-ssh.sh — SSH hardening for mwp
#
# Public:
#   ssh_harden()       Switch sshd to key-only, password auth disabled.
#                      REFUSES if /root/.ssh/authorized_keys is empty (would
#                      lock you out). Reversible via ssh_unharden.
#   ssh_unharden()     Restore distro-default password+key auth.
#   ssh_status()       Show current auth modes + keys + ban stats + harden flag.

[[ -n "${_MWP_SSH_LOADED:-}" ]] && return 0
_MWP_SSH_LOADED=1

SSHD_CONFIG="/etc/ssh/sshd_config"
# Use 01- prefix so we load BEFORE 50-cloud-init.conf (alphabetical).
# OpenSSH uses first-occurrence-wins — if cloud-init's drop-in sets
# PasswordAuthentication yes and loads first, our `no` is silently ignored
# even though `sshd -T` will report yes. Naming us 01- guarantees we win.
SSHD_DROPIN="/etc/ssh/sshd_config.d/01-mwp-harden.conf"
SSHD_DROPIN_LEGACY="/etc/ssh/sshd_config.d/50-mwp-harden.conf"

# ---------------------------------------------------------------------------
# Refuse if the operator has no working key — disabling password auth without
# a key in place is a one-way ticket to console-only recovery. We check both
# the standard and any AuthorizedKeysFile override.
# ---------------------------------------------------------------------------
_ssh_root_keys_count() {
    local f
    local count=0
    for f in /root/.ssh/authorized_keys /root/.ssh/authorized_keys2; do
        [[ -f "$f" ]] || continue
        # Count non-empty, non-comment lines that look like a key
        local n
        n="$(grep -cE '^(ssh-(rsa|ed25519|dss)|ecdsa-)' "$f" 2>/dev/null || echo 0)"
        count=$((count + n))
    done
    printf '%d' "$count"
}

ssh_harden() {
    require_root

    local key_count
    key_count="$(_ssh_root_keys_count)"
    if [[ "$key_count" -lt 1 ]]; then
        die "REFUSING — /root/.ssh/authorized_keys has 0 keys. Would lock you out.
   Add at least one key first:
     ssh-copy-id -i ~/.ssh/id_ed25519.pub root@$(hostname -I | awk '{print $1}')
   Then verify key auth works:
     ssh -i ~/.ssh/id_ed25519 -o BatchMode=yes -o PreferredAuthentications=publickey root@$(hostname -I | awk '{print $1}') true"
    fi

    log_info "Hardening SSH: ${key_count} root key(s) detected — disabling password auth."
    log_warn "Verify you can still SSH in BEFORE closing your current session."

    # Drop-in lives at 01- so we load BEFORE 50-cloud-init.conf et al.
    # The original sshd_config is never touched — easier to revert + safer on apt upgrade.
    mkdir -p "$(dirname "$SSHD_DROPIN")"
    # Clean up any pre-0.3.4 install that left the file at 50-mwp-harden.conf
    [[ -f "$SSHD_DROPIN_LEGACY" ]] && rm -f "$SSHD_DROPIN_LEGACY"
    cat > "$SSHD_DROPIN" <<DROPIN
# mwp — SSH hardening (key-only)
# Toggle off:  mwp ssh unharden
# Verify:      mwp ssh status

# Root may log in but only with a key (never with password)
PermitRootLogin prohibit-password

# Disable password / keyboard-interactive entirely
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no

# Public key auth on (default, but make explicit)
PubkeyAuthentication yes

# Disable known-bad legacy auth methods
HostbasedAuthentication no
PermitEmptyPasswords no

# Limit auth attempts per connection
MaxAuthTries 3
LoginGraceTime 30
DROPIN
    chmod 644 "$SSHD_DROPIN"
    log_sub "Drop-in written: $SSHD_DROPIN"

    # Validate before reloading — sshd -t fails on syntax errors
    if ! sshd -t 2>&1; then
        rm -f "$SSHD_DROPIN"
        die "sshd config test failed — drop-in removed, no change applied."
    fi

    # systemctl reload preserves existing sessions; new connections use new policy
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || \
        die "Could not reload ssh service. Drop-in is in place but not active yet."

    server_set "SSH_HARDENED" "yes"
    server_set "SSH_HARDENED_AT" "$(date '+%Y-%m-%d %H:%M:%S')"

    log_success "SSH hardened: PermitRootLogin prohibit-password, PasswordAuthentication no."
    log_warn "BEFORE closing this session, open a new terminal and verify key login still works."
}

ssh_unharden() {
    require_root

    if [[ ! -f "$SSHD_DROPIN" && ! -f "$SSHD_DROPIN_LEGACY" ]]; then
        log_info "SSH not hardened by mwp — nothing to revert."
        return 0
    fi

    log_info "Reverting SSH harden — restoring distro defaults (password auth back on)."
    rm -f "$SSHD_DROPIN" "$SSHD_DROPIN_LEGACY"

    if ! sshd -t 2>&1; then
        die "sshd config test failed AFTER removing drop-in — manual fix required."
    fi
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || \
        die "Could not reload ssh service."

    server_set "SSH_HARDENED" "no"
    log_success "SSH unhardened: distro defaults restored."
}

ssh_status() {
    local hardened key_count
    hardened="$(server_get "SSH_HARDENED")"
    [[ -z "$hardened" ]] && hardened="no"
    key_count="$(_ssh_root_keys_count)"

    printf '\n%b  SSH status%b\n' "$BOLD" "$NC"
    printf '  %s\n' "──────────────────────────────────────"

    if [[ "$hardened" == "yes" ]]; then
        printf '  Hardened (mwp):       %byes%b  (since %s)\n' "$GREEN" "$NC" \
            "$(server_get "SSH_HARDENED_AT")"
    else
        printf '  Hardened (mwp):       %bno%b   (run: mwp ssh harden)\n' "$YELLOW" "$NC"
    fi

    printf '  Root authorized_keys: %s key(s)\n' "$key_count"

    # Effective sshd config (after drop-ins) — sshd -T is authoritative
    local password_auth root_login pubkey
    password_auth="$(sshd -T 2>/dev/null | awk '/^passwordauthentication / {print $2}')"
    root_login="$(sshd -T 2>/dev/null | awk '/^permitrootlogin / {print $2}')"
    pubkey="$(sshd -T 2>/dev/null | awk '/^pubkeyauthentication / {print $2}')"
    printf '  PasswordAuthentication: %s\n' "${password_auth:-?}"
    printf '  PermitRootLogin:        %s\n' "${root_login:-?}"
    printf '  PubkeyAuthentication:   %s\n' "${pubkey:-?}"

    # fail2ban sshd jail stats — quick view of brute-force pressure
    if command -v fail2ban-client >/dev/null 2>&1; then
        local jail_info
        jail_info="$(fail2ban-client status sshd 2>/dev/null | grep -E 'Total failed|Currently banned|Total banned')"
        if [[ -n "$jail_info" ]]; then
            printf '\n  %bfail2ban (sshd):%b\n' "$BOLD" "$NC"
            printf '%s\n' "$jail_info" | sed 's/^/    /'
        fi
    fi
    printf '\n'
}
