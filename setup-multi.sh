#!/usr/bin/env bash
# setup-multi.sh — mwp one-liner installer
# Usage: curl -sSL https://raw.githubusercontent.com/azsmarthub/m-wp/main/setup-multi.sh | bash
# Or:    bash setup-multi.sh [--dir /opt/m-wp] [--branch main]

set -euo pipefail

MWP_INSTALL_DIR="${MWP_INSTALL_DIR:-/opt/m-wp}"
MWP_REPO="${MWP_REPO:-https://github.com/azsmarthub/m-wp.git}"
MWP_BRANCH="${MWP_BRANCH:-main}"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)    MWP_INSTALL_DIR="$2"; shift 2 ;;
        --branch) MWP_BRANCH="$2";      shift 2 ;;
        --repo)   MWP_REPO="$2";        shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'

die()  { printf '%b✗%b  %s\n' "$RED" "$NC" "$1" >&2; exit 1; }
ok()   { printf '%b✔%b  %s\n' "$GREEN" "$NC" "$1"; }
info() { printf '    %s\n' "$1"; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash setup-multi.sh"

printf '\n%b════════════════════════════════════════%b\n' "$BOLD" "$NC"
printf '%b   mwp — Multi-site WordPress Setup%b\n'      "$BOLD" "$NC"
printf '%b════════════════════════════════════════%b\n\n' "$BOLD" "$NC"

info "Install dir: $MWP_INSTALL_DIR"
info "Branch:      $MWP_BRANCH"
info "Repo:        $MWP_REPO"
printf '\n'

# Check OS
if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    case "${ID:-}" in
        ubuntu)
            case "${VERSION_ID:-}" in
                22.04|24.04) ok "OS: Ubuntu $VERSION_ID" ;;
                *) printf '%b!%b  Untested OS: Ubuntu %s (recommended: 22.04 / 24.04)\n' \
                       '\033[1;33m' "$NC" "${VERSION_ID:-unknown}" ;;
            esac
            ;;
        *) printf '%b!%b  Untested OS: %s\n' '\033[1;33m' "$NC" "${PRETTY_NAME:-unknown}" ;;
    esac
else
    die "Cannot detect OS"
fi

# Install git if needed
if ! command -v git >/dev/null 2>&1; then
    info "Installing git..."
    apt-get update -qq 2>&1 | tail -1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q git 2>&1 | tail -2 || true
fi
ok "git available"

# Clone or update repo
if [[ -d "$MWP_INSTALL_DIR/.git" ]]; then
    info "Updating existing installation at $MWP_INSTALL_DIR..."
    git -C "$MWP_INSTALL_DIR" fetch origin 2>/dev/null
    git -C "$MWP_INSTALL_DIR" checkout "$MWP_BRANCH" 2>/dev/null
    git -C "$MWP_INSTALL_DIR" pull --ff-only origin "$MWP_BRANCH" 2>/dev/null
    ok "Updated to latest ($MWP_BRANCH)"
else
    info "Cloning mwp to $MWP_INSTALL_DIR..."
    git clone --depth=1 --branch "$MWP_BRANCH" "$MWP_REPO" "$MWP_INSTALL_DIR" 2>/dev/null
    ok "Cloned to $MWP_INSTALL_DIR"
fi

# Make scripts executable
chmod +x "$MWP_INSTALL_DIR/multi/install.sh" \
          "$MWP_INSTALL_DIR/multi/menu.sh" \
          "$MWP_INSTALL_DIR/lib/"*.sh
ok "Scripts executable"

# Run server setup
printf '\n%b  Starting server setup...%b\n\n' "$BOLD" "$NC"
export MWP_DIR="$MWP_INSTALL_DIR"
exec bash "$MWP_INSTALL_DIR/multi/install.sh"
