#!/usr/bin/env bash
# lib/multi-cf.sh — Cloudflare IP restriction for production hardening (P1c)
#
# Use case: all sites on the box are CF-proxied. Direct hits to :80/:443 from
# non-CF IPs are bots scanning wp-login.php / xmlrpc.php / known CVE paths
# (we observed this within 30s of bringing affcms.azsmarthub.com up). Block
# the entire non-CF internet at the firewall.
#
# Two coordinated changes:
#   1. UFW: deny default 80/443, allow 80/443 ONLY from CF IPv4+IPv6 ranges
#   2. Nginx: set_real_ip_from + real_ip_header CF-Connecting-IP so access
#      logs + fail2ban see the actual visitor IP, not the CF edge IP
#      (otherwise fail2ban would only ever ban CF, locking everyone out)
#
# Safety guards (refuse if):
#   - Admin IP whitelist (mwp install whitelist) missing → would lock out admin
#   - Any registered site is NOT CF-proxied → that site would break
#
# Public:
#   cf_restrict_on    Apply CF-only restriction
#   cf_restrict_off   Revert to allow-all on 80/443
#   cf_status         Show current restriction state + CF IP cache age
#   cf_refresh        Re-fetch CF IPs from cloudflare.com (cron weekly)

[[ -n "${_MWP_CF_LOADED:-}" ]] && return 0
_MWP_CF_LOADED=1

CF_IPS_V4_URL="https://www.cloudflare.com/ips-v4"
CF_IPS_V6_URL="https://www.cloudflare.com/ips-v6"
CF_IPS_V4_FILE="$MWP_STATE_DIR/cf-ips-v4"
CF_IPS_V6_FILE="$MWP_STATE_DIR/cf-ips-v6"
CF_NGINX_SNIPPET="/etc/nginx/conf.d/mwp-cf-realip.conf"
CF_REFRESH_CRON="/etc/cron.weekly/mwp-cf-refresh"

# ---------------------------------------------------------------------------
# CF guard string used in vhost templates. Helper for site_create/app_create:
# echo the right `if (...) { return 444; }` line for CF-proxied domains, or
# empty for direct-DNS domains. nginx_render then substitutes {{CF_GUARD}}.
#
# Returns the literal CF guard line on stdout. Caller decides what domain
# this applies to before calling.
# ---------------------------------------------------------------------------
cf_guard_for_cf_proxied() {
    printf 'if ($mwp_is_cf_source = 0) { return 444; }'
}

cf_guard_empty() {
    printf '# (direct-DNS domain — no CF guard)'
}

# Decide CF guard based on a domain's current DNS. Echoes the appropriate
# nginx snippet to stdout. Used by site_create + app_create at vhost render.
cf_guard_for_domain() {
    local domain="$1"
    local apex_ip
    apex_ip="$( set +o pipefail; dig +short A "$domain" 2>/dev/null \
                | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -1 )"
    if [[ -n "$apex_ip" ]] && is_cloudflare_ip "$apex_ip"; then
        cf_guard_for_cf_proxied
    else
        cf_guard_empty
    fi
}

# ---------------------------------------------------------------------------
# Fetch + cache CF IP ranges. Returns 0 if successful, 1 if upstream unreachable.
# ---------------------------------------------------------------------------
cf_refresh() {
    require_root
    log_info "Fetching Cloudflare IP ranges..."
    local v4 v6
    v4="$(curl -fsSL --max-time 10 "$CF_IPS_V4_URL" 2>/dev/null)" || true
    v6="$(curl -fsSL --max-time 10 "$CF_IPS_V6_URL" 2>/dev/null)" || true

    if [[ -z "$v4" ]]; then
        log_error "Could not fetch $CF_IPS_V4_URL — keeping cached ranges if any."
        [[ -f "$CF_IPS_V4_FILE" ]] && return 0 || return 1
    fi

    # Sanity: each line should be a CIDR. Reject if anything looks off.
    if ! printf '%s\n' "$v4" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; then
        log_error "CF IPv4 list looks malformed — refusing to overwrite cache."
        return 1
    fi

    printf '%s\n' "$v4" > "$CF_IPS_V4_FILE"
    [[ -n "$v6" ]] && printf '%s\n' "$v6" > "$CF_IPS_V6_FILE"
    chmod 644 "$CF_IPS_V4_FILE" "$CF_IPS_V6_FILE" 2>/dev/null

    server_set "CF_IPS_REFRESHED" "$(date '+%Y-%m-%d %H:%M:%S')"
    log_success "CF IPs refreshed: $(wc -l < "$CF_IPS_V4_FILE") IPv4, $(wc -l < "$CF_IPS_V6_FILE" 2>/dev/null || echo 0) IPv6 ranges."

    # ALWAYS apply nginx map (real_ip + geo block) — per-vhost CF guard is
    # part of the always-on protection model. UFW global lockdown is just a
    # bonus paranoid mode on top.
    _cf_apply_nginx_realip

    # If UFW restriction is currently on, refresh those rules too with new ranges
    if [[ "$(server_get "CF_RESTRICTED")" == "yes" ]]; then
        log_sub "UFW global lockdown is on — re-applying CF allowlist..."
        _cf_apply_ufw_rules
    fi
}

# ---------------------------------------------------------------------------
# Pre-flight: would enabling CF-only break anything?
# ---------------------------------------------------------------------------
_cf_safety_check() {
    local issues=0

    # 1. Admin IP must be whitelisted in UFW so we don't self-lock
    if ! ufw status 2>/dev/null | grep -q "mwp admin whitelist"; then
        log_error "No 'mwp admin whitelist' rule in UFW. Refusing — you'd be locked out."
        log_sub  "Add your IP first with the install whitelist script, e.g.:"
        log_sub  "  ufw allow from <YOUR_PUBLIC_IP> comment 'mwp admin whitelist'"
        issues=$(( issues + 1 ))
    fi

    # 2. Every registered site must resolve to a CF IP, else that site breaks
    local conf domain apex non_cf=()
    for conf in "$MWP_SITES_DIR"/*.conf; do
        [[ -f "$conf" ]] || continue
        domain="$(grep "^DOMAIN=" "$conf" | cut -d= -f2-)"
        apex="$( set +o pipefail; dig +short A "$domain" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -1 )"
        if [[ -z "$apex" ]]; then
            log_warn "  $domain → DNS unresolved (skipping check)"
            continue
        fi
        if ! is_cloudflare_ip "$apex"; then
            non_cf+=("$domain  (DNS → $apex)")
        fi
    done

    # Apps too — they share the same nginx
    if [[ -d "$MWP_APPS_DIR" ]]; then
        for conf in "$MWP_APPS_DIR"/*.conf; do
            [[ -f "$conf" ]] || continue
            domain="$(grep "^DOMAIN=" "$conf" | cut -d= -f2-)"
            apex="$( set +o pipefail; dig +short A "$domain" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -1 )"
            [[ -z "$apex" ]] && continue
            if ! is_cloudflare_ip "$apex"; then
                non_cf+=("$domain  (app, DNS → $apex)")
            fi
        done
    fi

    if [[ ${#non_cf[@]} -gt 0 ]]; then
        log_error "These sites/apps are NOT CF-proxied — they will be UNREACHABLE after restrict:"
        printf '    %s\n' "${non_cf[@]}"
        log_sub "Either CF-proxy them first OR don't enable cf restrict."
        issues=$(( issues + 1 ))
    fi

    return $issues
}

# ---------------------------------------------------------------------------
# UFW: replace default ALLOW 80/443 ANYWHERE with CF-only ALLOW rules.
# Tagged with comment 'mwp-cf' for clean removal in cf_restrict_off.
# ---------------------------------------------------------------------------
_cf_apply_ufw_rules() {
    log_sub "Re-applying UFW 80/443 rules (CF-only)..."

    # UFW pads single-digit rule numbers with leading spaces: "[ 2]" not "[2]".
    # Regex must use \s* inside the brackets, otherwise we never find the rule
    # to delete and the lockdown silently no-ops while pretending to succeed.

    # Wipe old mwp-cf rules
    while ufw status numbered 2>/dev/null | grep -q "mwp-cf"; do
        local n
        n="$(ufw status numbered 2>/dev/null | grep "mwp-cf" | head -1 \
             | grep -oE '\[\s*[0-9]+\s*\]' | tr -d '[ ]')"
        [[ -z "$n" ]] && break
        # `printf 'y\n'` instead of `yes y` — `yes` writes infinitely and gets
        # SIGPIPE'd as soon as `ufw delete` closes stdin after reading one 'y'.
        # Under `set -o pipefail` that SIGPIPE makes the pipeline exit non-zero,
        # which trips the `|| break` and silently exits the loop after deleting
        # exactly one rule. printf sends exactly one line then EOF cleanly.
        printf 'y\n' | ufw delete "$n" >/dev/null 2>&1 || break
    done

    # Wipe default 80/443 ALLOW ANYWHERE rules. Match end-of-line so we don't
    # accidentally delete commented variants. Use 80,443/tcp and 80/tcp + 443/tcp
    # both shapes — UFW collapses or splits depending on how the rule was added.
    local pattern='^\[\s*[0-9]+\s*\]\s+(80|443|80,443)/tcp\s+ALLOW IN\s+Anywhere(\s+\(v6\))?\s*$'
    while ufw status numbered 2>/dev/null | grep -qE "$pattern"; do
        local n
        n="$(ufw status numbered 2>/dev/null | grep -E "$pattern" | head -1 \
             | grep -oE '\[\s*[0-9]+\s*\]' | tr -d '[ ]')"
        [[ -z "$n" ]] && break
        # `printf 'y\n'` instead of `yes y` — `yes` writes infinitely and gets
        # SIGPIPE'd as soon as `ufw delete` closes stdin after reading one 'y'.
        # Under `set -o pipefail` that SIGPIPE makes the pipeline exit non-zero,
        # which trips the `|| break` and silently exits the loop after deleting
        # exactly one rule. printf sends exactly one line then EOF cleanly.
        printf 'y\n' | ufw delete "$n" >/dev/null 2>&1 || break
    done

    # Add CF-only rules (one per CIDR — UFW doesn't aggregate)
    local cidr count=0
    while IFS= read -r cidr; do
        [[ -z "$cidr" ]] && continue
        ufw allow proto tcp from "$cidr" to any port 80,443 comment "mwp-cf" >/dev/null 2>&1 || true
        count=$(( count + 1 ))
    done < "$CF_IPS_V4_FILE"

    if [[ -f "$CF_IPS_V6_FILE" ]]; then
        while IFS= read -r cidr; do
            [[ -z "$cidr" ]] && continue
            ufw allow proto tcp from "$cidr" to any port 80,443 comment "mwp-cf" >/dev/null 2>&1 || true
            count=$(( count + 1 ))
        done < "$CF_IPS_V6_FILE"
    fi

    ufw reload >/dev/null 2>&1 || true
    log_sub "UFW: $count CF CIDR rules in place; default 80/443 ALLOW removed."
}

# ---------------------------------------------------------------------------
# Nginx: set_real_ip_from + real_ip_header. Without this, every connection
# would log + fail2ban-ban CF edge IPs, breaking the entire site for everyone.
# ---------------------------------------------------------------------------
_cf_apply_nginx_realip() {
    log_sub "Updating nginx CF-IP map (real_ip + geo)..."

    # Ensure nginx.conf includes /etc/nginx/conf.d/*.conf in http {} (required
    # for our snippet to be loaded). install.sh ships a minimal nginx.conf
    # that only has the sites-enabled include — patch in conf.d if missing.
    local nginx_conf="/etc/nginx/nginx.conf"
    if [[ -f "$nginx_conf" ]] && ! grep -q "include /etc/nginx/conf.d" "$nginx_conf"; then
        sed -i 's|^\(\s*\)include /etc/nginx/sites-enabled/\*\.conf;|\1include /etc/nginx/conf.d/*.conf;\n\1include /etc/nginx/sites-enabled/*.conf;|' \
            "$nginx_conf"
        log_sub "Patched nginx.conf to include /etc/nginx/conf.d/*.conf"
    fi
    [[ -d /etc/nginx/conf.d ]] || mkdir -p /etc/nginx/conf.d

    {
        printf '# mwp — Cloudflare IP map (real-IP + per-vhost source guard)\n'
        printf '# Generated %s — re-run "mwp cf refresh" to update\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"

        # Block 1: set_real_ip_from — so nginx logs + fail2ban see real
        # visitor IPs (via CF-Connecting-IP header) instead of the CF edge IP
        local cidr
        while IFS= read -r cidr; do
            [[ -z "$cidr" ]] && continue
            printf 'set_real_ip_from %s;\n' "$cidr"
        done < "$CF_IPS_V4_FILE"
        if [[ -f "$CF_IPS_V6_FILE" ]]; then
            while IFS= read -r cidr; do
                [[ -z "$cidr" ]] && continue
                printf 'set_real_ip_from %s;\n' "$cidr"
            done < "$CF_IPS_V6_FILE"
        fi
        printf '\nreal_ip_header CF-Connecting-IP;\nreal_ip_recursive on;\n\n'

        # Block 2: geo $mwp_is_cf_source — per-request flag used by vhosts
        # marked as CF-proxied. CRITICAL: use $realip_remote_addr (the ORIGINAL
        # TCP source IP, before set_real_ip_from rewrites it). If we used plain
        # $remote_addr, real_ip would already have replaced it with the
        # CF-Connecting-IP header value (the actual visitor) and we would block
        # *every* CF request because the visitor IPs are not in CF range.
        printf 'geo $realip_remote_addr $mwp_is_cf_source {\n'
        printf '    default 0;\n'
        while IFS= read -r cidr; do
            [[ -z "$cidr" ]] && continue
            printf '    %s 1;\n' "$cidr"
        done < "$CF_IPS_V4_FILE"
        if [[ -f "$CF_IPS_V6_FILE" ]]; then
            while IFS= read -r cidr; do
                [[ -z "$cidr" ]] && continue
                printf '    %s 1;\n' "$cidr"
            done < "$CF_IPS_V6_FILE"
        fi
        printf '}\n'
    } > "$CF_NGINX_SNIPPET"
    chmod 644 "$CF_NGINX_SNIPPET"

    nginx -t >/dev/null 2>&1 || die "nginx config test failed after CF map regeneration"
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
    log_sub "Nginx CF map: real_ip + \$mwp_is_cf_source geo block ready."
}

# ---------------------------------------------------------------------------
# Install weekly cron to refresh CF IPs (CF rotates ranges occasionally)
# ---------------------------------------------------------------------------
_cf_install_refresh_cron() {
    # Install at install time (step_isolation) — kept as a no-op convenience
    # here for older install paths.
    if [[ ! -f "$CF_REFRESH_CRON" ]]; then
        cat > "$CF_REFRESH_CRON" <<'CRON'
#!/bin/sh
/usr/local/bin/mwp cf refresh >/var/log/mwp/cf-refresh.log 2>&1
CRON
        chmod 755 "$CF_REFRESH_CRON"
    fi
}

cf_restrict_on() {
    require_root
    [[ -f "$CF_IPS_V4_FILE" ]] || cf_refresh

    log_info "Pre-flight check..."
    if ! _cf_safety_check; then
        die "Pre-flight failed. Fix the issues above, then re-run."
    fi
    log_sub "Pre-flight OK."

    _cf_apply_ufw_rules
    _cf_apply_nginx_realip
    _cf_install_refresh_cron

    server_set "CF_RESTRICTED" "yes"
    server_set "CF_RESTRICTED_AT" "$(date '+%Y-%m-%d %H:%M:%S')"

    log_success "CF restriction enabled."
    log_sub "Direct (non-CF) hits to :80/:443 are now dropped at UFW."
    log_sub "Nginx logs + fail2ban now see real visitor IPs via CF-Connecting-IP."
    log_sub "Weekly auto-refresh cron installed: $CF_REFRESH_CRON"
}

cf_restrict_off() {
    require_root

    log_info "Removing CF restriction..."

    # Wipe all mwp-cf UFW rules (same regex caveat — UFW pads "[ 2]" with spaces)
    local count=0
    while ufw status numbered 2>/dev/null | grep -q "mwp-cf"; do
        local n
        n="$(ufw status numbered 2>/dev/null | grep "mwp-cf" | head -1 \
             | grep -oE '\[\s*[0-9]+\s*\]' | tr -d '[ ]')"
        [[ -z "$n" ]] && break
        # `printf 'y\n'` instead of `yes y` — `yes` writes infinitely and gets
        # SIGPIPE'd as soon as `ufw delete` closes stdin after reading one 'y'.
        # Under `set -o pipefail` that SIGPIPE makes the pipeline exit non-zero,
        # which trips the `|| break` and silently exits the loop after deleting
        # exactly one rule. printf sends exactly one line then EOF cleanly.
        printf 'y\n' | ufw delete "$n" >/dev/null 2>&1 || break
        count=$(( count + 1 ))
    done

    # Restore default ALLOW 80/443
    ufw allow 80/tcp  >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    ufw reload >/dev/null 2>&1 || true

    # Remove nginx snippet + reload
    rm -f "$CF_NGINX_SNIPPET"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null

    # Remove cron
    rm -f "$CF_REFRESH_CRON"

    server_set "CF_RESTRICTED" "no"
    log_success "CF restriction removed: $count CF rules dropped, default 80/443 restored."
}

cf_status() {
    local restricted refreshed cf_v4_count cf_v6_count
    restricted="$(server_get "CF_RESTRICTED")"
    refreshed="$(server_get "CF_IPS_REFRESHED")"
    cf_v4_count="$(wc -l < "$CF_IPS_V4_FILE" 2>/dev/null || echo 0)"
    cf_v6_count="$(wc -l < "$CF_IPS_V6_FILE" 2>/dev/null || echo 0)"

    printf '\n%b  Cloudflare restriction status%b\n' "$BOLD" "$NC"
    printf '  %s\n' "──────────────────────────────────────"

    if [[ "$restricted" == "yes" ]]; then
        printf '  Restriction:    %bON%b   (since %s)\n' "$GREEN" "$NC" \
            "$(server_get "CF_RESTRICTED_AT")"
    else
        printf '  Restriction:    %bOFF%b  (run: mwp cf restrict-on)\n' "$YELLOW" "$NC"
    fi

    printf '  CF IP cache:    %s IPv4, %s IPv6 ranges\n' "$cf_v4_count" "$cf_v6_count"
    [[ -n "$refreshed" ]] && printf '  Last refresh:   %s\n' "$refreshed"

    # Show current UFW 80/443 rule count
    local cf_rules
    cf_rules="$(ufw status 2>/dev/null | grep -c "mwp-cf")"
    printf '  UFW mwp-cf:     %s rule(s)\n' "$cf_rules"

    # Nginx real-IP snippet present?
    if [[ -f "$CF_NGINX_SNIPPET" ]]; then
        printf '  Nginx real-IP:  %bactive%b (%s)\n' "$GREEN" "$NC" "$CF_NGINX_SNIPPET"
    else
        printf '  Nginx real-IP:  %binactive%b (no CF header parsing)\n' "$YELLOW" "$NC"
    fi
    printf '\n'
}
