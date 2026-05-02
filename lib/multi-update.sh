#!/usr/bin/env bash
# lib/multi-update.sh — mwp self-update
#
# Two channels:
#   stable (default) — latest GitHub release tag (e.g. v0.5.1)
#   main             — bleeding-edge HEAD of origin/main
#
# Data safety:
#   git pull only touches /opt/m-wp (the script repo). State lives in
#   /etc/mwp, /home/<user>/, MariaDB, /etc/nginx, /etc/letsencrypt — none
#   of which this command touches. Existing sites keep running on their
#   already-deployed nginx/PHP/DB. The next mwp invocation uses the new
#   code with the same on-disk state.
#
# Public:
#   update_status()   Show current + remote (latest tag + main behind/ahead)
#   update_check()    Dry-run: list pending commits without applying
#   update_apply()    Pull + chmod (+ --main / --tag / --force / --check)

[[ -n "${_MWP_UPDATE_LOADED:-}" ]] && return 0
_MWP_UPDATE_LOADED=1

GITHUB_API_REPO="${MWP_GITHUB_API:-https://api.github.com/repos/azsmarthub/m-wp}"

# ---------------------------------------------------------------------------
# Latest release tag from GitHub API. Empty string if API unreachable or
# the repo has no releases yet (in which case caller falls back to main).
# Uses curl + sed — no jq dep.
#
# Wrapped in subshell with `set +o pipefail` because grep returns 1 on
# no-match (e.g. before the first release is tagged), and under the
# parent script's pipefail that would propagate out of the $(...) and
# trip set -e — turning a graceful "no release found" into a hard die.
# ---------------------------------------------------------------------------
update_get_latest_tag() {
    ( set +o pipefail
      curl -fsSL --max-time 5 "$GITHUB_API_REPO/releases/latest" 2>/dev/null \
          | grep '"tag_name"' \
          | head -1 \
          | sed 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/' )
}

# clean | dirty | not-a-repo
update_repo_state() {
    [[ -d "$MWP_DIR/.git" ]] || { printf 'not-a-repo'; return; }
    if git -C "$MWP_DIR" status --porcelain 2>/dev/null | grep -q .; then
        printf 'dirty'
    else
        printf 'clean'
    fi
}

# ---------------------------------------------------------------------------
# Status — what's installed, what's available. Always safe to run.
# ---------------------------------------------------------------------------
update_status() {
    local current latest_tag local_branch local_sha behind ahead state

    current="$MWP_VERSION"
    state="$(update_repo_state)"

    printf '\n%b  mwp version status%b\n' "$BOLD" "$NC"
    printf '  %s\n' "──────────────────────────────────────"
    printf '  Local version:    %s\n' "$current"
    printf '  Install dir:      %s\n' "$MWP_DIR"
    printf '  Repo state:       %s\n' "$state"

    if [[ "$state" == "not-a-repo" ]]; then
        printf '  %b!%b  Not a git checkout — cannot self-update.\n' "$YELLOW" "$NC"
        printf '     (Re-install via: bash <(curl -fsSL https://raw.githubusercontent.com/azsmarthub/m-wp/main/setup-multi.sh))\n\n'
        return
    fi

    local_branch="$(git -C "$MWP_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    local_sha="$(git -C "$MWP_DIR" rev-parse --short HEAD 2>/dev/null)"
    printf '  Branch / commit:  %s @ %s\n' "$local_branch" "$local_sha"

    log_info "Checking GitHub..."
    if ! git -C "$MWP_DIR" fetch --tags --quiet origin 2>/dev/null; then
        log_warn "Could not fetch from origin — offline or rate-limited."
        printf '\n'
        return
    fi

    behind="$(git -C "$MWP_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
    ahead="$( git -C "$MWP_DIR" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
    printf '  vs origin/main:   '
    if   [[ "$behind" -gt 0 && "$ahead" -gt 0 ]]; then
        printf '%bdiverged%b (behind %s, ahead %s)\n' "$RED" "$NC" "$behind" "$ahead"
    elif [[ "$behind" -gt 0 ]]; then
        printf '%bbehind by %s%b commit(s) — run: %bmwp update --main%b\n' \
            "$YELLOW" "$NC" "$behind" "$BOLD" "$NC"
    elif [[ "$ahead" -gt 0 ]]; then
        printf '%bahead by %s%b (local commits not pushed)\n' "$YELLOW" "$NC" "$ahead"
    else
        printf '%bup to date with main%b\n' "$GREEN" "$NC"
    fi

    latest_tag="$(update_get_latest_tag)"
    if [[ -n "$latest_tag" ]]; then
        local cur_norm="${current#v}"
        local tag_norm="${latest_tag#v}"
        printf '  Latest release:   %s' "$latest_tag"
        if [[ "$cur_norm" != "$tag_norm" ]]; then
            printf '  %b(new! run: mwp update)%b' "$GREEN" "$NC"
        else
            printf '  %b(matches local)%b' "$DIM" "$NC"
        fi
        printf '\n'
    else
        printf '  Latest release:   (no GitHub releases yet — use --main)\n'
    fi
    printf '\n'
}

# ---------------------------------------------------------------------------
# Dry-run: list commits between HEAD and the chosen target ref.
# Args: optional target ref (default = latest tag, fall back to origin/main).
# ---------------------------------------------------------------------------
update_check() {
    [[ "$(update_repo_state)" == "not-a-repo" ]] && \
        die "Not a git checkout at $MWP_DIR — cannot self-update."

    log_info "Fetching from GitHub..."
    git -C "$MWP_DIR" fetch --tags --quiet origin || die "git fetch failed"

    local target="${1:-}"
    local target_label
    if [[ -z "$target" ]]; then
        target="$(update_get_latest_tag)"
        if [[ -z "$target" ]]; then
            target="origin/main"
            target_label="origin/main (no releases tagged yet)"
        else
            target_label="$target (latest release)"
        fi
    else
        target_label="$target"
    fi

    local cur_sha new_sha
    cur_sha="$(git -C "$MWP_DIR" rev-parse --short HEAD)"
    new_sha="$(git -C "$MWP_DIR" rev-parse --short "$target" 2>/dev/null)"
    [[ -z "$new_sha" ]] && die "Cannot resolve ref: $target"

    printf '\n%b  Pending changes%b\n' "$BOLD" "$NC"
    printf '  %s\n' "──────────────────────────────────────"
    printf '  Current:  %s\n' "$cur_sha"
    printf '  Target:   %s @ %s\n' "$new_sha" "$target_label"
    printf '\n'

    local count
    count="$(git -C "$MWP_DIR" rev-list --count "HEAD..$target" 2>/dev/null || echo 0)"
    if [[ "$count" -eq 0 ]]; then
        printf '  Already at %s — nothing to update.\n\n' "$target"
        return 0
    fi
    printf '  Commits to apply (%s):\n' "$count"
    git -C "$MWP_DIR" log "HEAD..$target" --oneline --no-decorate \
        --pretty=format:'    %h  %s' 2>/dev/null
    printf '\n\n  Apply with: %bmwp update%b\n\n' "$BOLD" "$NC"
}

# ---------------------------------------------------------------------------
# Apply update. Channels:
#   --main           → fast-forward to origin/main
#   --tag <tag>      → checkout a specific release tag (detached HEAD)
#   (default)        → checkout latest release tag
# Flags:
#   --check          → run update_check + return (no changes)
#   --force          → discard local modifications via git reset --hard
# ---------------------------------------------------------------------------
update_apply() {
    require_root

    local channel="stable"
    local target_tag=""
    local force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --main)   channel="main";  shift ;;
            --tag)    channel="tag";   target_tag="${2:-}"; shift 2 ;;
            --force)  force=1;         shift ;;
            --check)  update_check;    return 0 ;;
            *) die "Unknown flag: $1
   Usage: mwp update [--check] [--main|--tag <tag>] [--force]" ;;
        esac
    done

    [[ "$(update_repo_state)" == "not-a-repo" ]] && \
        die "Not a git checkout at $MWP_DIR — cannot self-update."

    if [[ "$channel" == "tag" && -z "$target_tag" ]]; then
        die "--tag requires a tag name (e.g. v0.5.1)"
    fi

    # Refuse on dirty tree (unless --force)
    if [[ "$(update_repo_state)" == "dirty" && $force -eq 0 ]]; then
        log_error "Working tree has local modifications:"
        git -C "$MWP_DIR" status --short | sed 's/^/    /'
        die "Refusing to update — commit, stash, or pass --force to discard."
    fi

    log_info "Fetching from GitHub..."
    git -C "$MWP_DIR" fetch --tags --quiet origin || die "git fetch failed (offline?)"

    local target_ref
    case "$channel" in
        stable)
            target_tag="$(update_get_latest_tag)"
            if [[ -z "$target_tag" ]]; then
                log_warn "No GitHub releases yet — falling back to origin/main."
                target_ref="origin/main"
                channel="main"
            else
                target_ref="$target_tag"
            fi
            ;;
        main) target_ref="origin/main" ;;
        tag)  target_ref="$target_tag" ;;
    esac

    local cur_sha new_sha
    cur_sha="$(git -C "$MWP_DIR" rev-parse --short HEAD)"
    new_sha="$(git -C "$MWP_DIR" rev-parse --short "$target_ref" 2>/dev/null)"
    [[ -z "$new_sha" ]] && die "Cannot resolve ref: $target_ref"

    if [[ "$cur_sha" == "$new_sha" ]]; then
        log_success "Already at $target_ref ($cur_sha) — no update needed."
        return 0
    fi

    log_info "Updating: $cur_sha → $new_sha  (channel: $channel, ref: $target_ref)"
    printf '\n  Commits being applied:\n'
    git -C "$MWP_DIR" log "HEAD..$target_ref" --oneline --no-decorate \
        --pretty=format:'    %h  %s' 2>/dev/null
    printf '\n\n'

    # Apply
    if [[ $force -eq 1 ]]; then
        # User explicitly opted to discard local changes
        git -C "$MWP_DIR" reset --hard "$target_ref" >/dev/null 2>&1 \
            || die "git reset --hard failed"
    elif [[ "$channel" == "main" ]]; then
        # Fast-forward main only — refuse on divergence (force needed).
        git -C "$MWP_DIR" checkout main --quiet 2>/dev/null \
            || die "git checkout main failed"
        git -C "$MWP_DIR" merge --ff-only "$target_ref" >/dev/null 2>&1 \
            || die "Cannot fast-forward main — branch diverged. Use --force to override."
    else
        # Tag (or stable=tag) — detached HEAD checkout
        git -C "$MWP_DIR" checkout --quiet "$target_ref" 2>/dev/null \
            || die "git checkout $target_ref failed"
    fi

    # Re-chmod entry-point scripts (lib/*.sh stays at default — chmod would
    # dirty the working tree on the next pull/check cycle).
    chmod +x "$MWP_DIR/multi/install.sh" "$MWP_DIR/multi/menu.sh" 2>/dev/null

    local new_ver
    new_ver="$(tr -d '[:space:]' < "$MWP_DIR/VERSION" 2>/dev/null)"
    log_success "mwp updated to v${new_ver:-?}  ($new_sha)"
    log_sub "Channel: $channel  |  Ref: $target_ref"
    log_sub "Existing sites untouched — re-run 'mwp' to pick up the new version."
}
