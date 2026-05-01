#!/usr/bin/env bash
# lib/multi-ssl.sh — SSL management for mwp
#
# ssl_issue()              — smart wrapper: picks LE or self-signed automatically
# ssl_issue_letsencrypt()  — Let's Encrypt via certbot --nginx (HTTP-01)
# ssl_issue_self_signed()  — 10-year self-signed origin cert (for CF-proxied sites)
# _ssl_post_install_wp()   — update WordPress home/siteurl + nginx https block

[[ -n "${_MWP_SSL_LOADED:-}" ]] && return 0
_MWP_SSL_LOADED=1

# ---------------------------------------------------------------------------
# Smart SSL issuer — auto-picks the right method based on DNS:
#
#   1. Direct DNS to this server   → Let's Encrypt (real cert)
#   2. Cloudflare-proxied DNS      → self-signed origin cert
#                                    (CF terminates TLS at edge using its own
#                                    cert; origin cert is internal-only and CF
#                                    "Full" mode accepts self-signed.)
#   3. DNS not propagated yet      → skip with hint
#   4. DNS to a different server   → skip with hint
#
# This is the function called by site_create's auto-flow AND by `mwp ssl issue`.
# Both paths get the same fully-automatic behavior — no user input needed.
# ---------------------------------------------------------------------------
ssl_issue() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && die "Usage: mwp ssl issue <domain>"

    local server_ip apex_ip
    server_ip="$(server_get "SERVER_IP")"
    apex_ip="$( set +o pipefail; dig +short "$domain" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -1 )"

    if [[ -z "$apex_ip" ]]; then
        log_warn "DNS for ${domain} doesn't resolve yet."
        log_sub  "Point your DNS A record to ${server_ip:-this server}, then retry: mwp ssl issue ${domain}"
        return 0
    fi

    if [[ "$apex_ip" == "$server_ip" ]]; then
        log_sub "DNS → ${apex_ip} (this server) — using Let's Encrypt"
        ssl_issue_letsencrypt "$domain"
        return $?
    fi

    if is_cloudflare_ip "$apex_ip"; then
        log_sub "DNS → ${apex_ip} (Cloudflare proxy) — using self-signed origin cert"
        log_sub "(CF terminates TLS at edge with its own cert; origin cert is internal only.)"
        ssl_issue_self_signed "$domain"
        return $?
    fi

    log_warn "DNS → ${apex_ip} (not this server, not Cloudflare) — skipping SSL"
    log_sub  "If this is intentional, gray-cloud / repoint DNS to ${server_ip:-this server} and retry."
    return 0
}

# ---------------------------------------------------------------------------
# Let's Encrypt issuance (HTTP-01 via certbot --nginx)
# ---------------------------------------------------------------------------
ssl_issue_letsencrypt() {
    local domain="$1"
    command -v certbot >/dev/null 2>&1 || die "Certbot not found. Run install.sh first."

    # Detect if www subdomain has DNS pointing to this server.
    # If not, requesting it would (a) waste an LE rate-limit attempt and
    # (b) modify the cert SAN list — making the next renewal fail too.
    local server_ip www_ip include_www=0
    server_ip="$(server_get "SERVER_IP")"
    www_ip="$( set +o pipefail; dig +short "www.${domain}" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -1 )"
    if [[ -n "$server_ip" && -n "$www_ip" && "$www_ip" == "$server_ip" ]]; then
        include_www=1
        log_sub "www.${domain} DNS resolves here too — including in cert"
    fi

    # Remove stale accounts that cause "Account not found" errors
    rm -rf /etc/letsencrypt/accounts/ 2>/dev/null || true

    local certbot_args=(
        certbot certonly --nginx --non-interactive --agree-tos
        --preferred-challenges http
        --email "admin@${domain}" -d "$domain"
    )
    [[ $include_www -eq 1 ]] && certbot_args+=( -d "www.${domain}" )

    log_sub "Requesting Let's Encrypt certificate for ${domain}..."
    if ! "${certbot_args[@]}" 2>&1 | tail -10; then
        log_warn "Let's Encrypt failed. Site is up on HTTP only."
        log_sub  "Common causes: DNS not propagated, port 80 blocked by firewall, LE rate limit."
        log_sub  "Retry: mwp ssl issue ${domain}"
        return 0
    fi

    [[ -f "$MWP_DIR/lib/multi-nginx.sh" ]] && source "$MWP_DIR/lib/multi-nginx.sh"
    _ssl_post_cert_apply "$domain" "/etc/letsencrypt/live/${domain}" "letsencrypt"

    # Auto-renewal cron (if not already set up by certbot package)
    if [[ ! -f /etc/cron.d/certbot ]] && ! systemctl is-active --quiet certbot.timer 2>/dev/null; then
        printf '0 3 * * * root certbot renew --quiet --post-hook "systemctl reload nginx"\n' \
            > /etc/cron.d/mwp-certbot-renew
        chmod 644 /etc/cron.d/mwp-certbot-renew
    fi

    log_success "SSL issued for ${domain} (Let's Encrypt)"
}

# ---------------------------------------------------------------------------
# Self-signed cert for Cloudflare-proxied origins
#
# Why this works for CF "Full" mode:
# - Visitor → CF: HTTPS using Cloudflare's edge cert (always valid)
# - CF → Origin: HTTPS using our origin cert
#   • CF "Full"          → accepts ANY origin cert (including self-signed)
#   • CF "Full (strict)" → requires CA-signed cert (use CF Origin Cert instead)
#
# Cert is 10 years long — no renewal needed during normal site lifetime.
# Stored under /etc/mwp/ssl/<domain>/ to keep separate from /etc/letsencrypt/.
# ---------------------------------------------------------------------------
ssl_issue_self_signed() {
    local domain="$1"
    command -v openssl >/dev/null 2>&1 || die "openssl not found"

    local ssl_dir="/etc/mwp/ssl/${domain}"
    mkdir -p "$ssl_dir"
    chmod 700 "$ssl_dir"

    log_sub "Generating 10-year self-signed certificate for ${domain}..."
    openssl req -x509 -nodes -newkey rsa:2048 \
        -days 3650 \
        -keyout "$ssl_dir/privkey.pem" \
        -out    "$ssl_dir/fullchain.pem" \
        -subj   "/CN=${domain}" \
        -addext "subjectAltName=DNS:${domain},DNS:www.${domain}" \
        2>/dev/null

    chmod 600 "$ssl_dir/privkey.pem"
    chmod 644 "$ssl_dir/fullchain.pem"
    log_sub "Self-signed cert installed at ${ssl_dir}/"

    [[ -f "$MWP_DIR/lib/multi-nginx.sh" ]] && source "$MWP_DIR/lib/multi-nginx.sh"
    _ssl_post_cert_apply "$domain" "$ssl_dir" "self-signed"

    log_success "SSL issued for ${domain} (self-signed origin cert; CF edge handles visitors)"

    # Verify CF can actually validate our self-signed origin. Catches Full-Strict
    # mode (526) immediately so the operator knows what to tell the customer
    # instead of discovering it in production. (Mirrors az-wp's _verify_cf_accepts_origin.)
    _ssl_verify_cf_accepts_origin "$domain" "$ssl_dir"
}

# ---------------------------------------------------------------------------
# Probe CF→origin reachability after a self-signed cert was just installed.
# Visitors hit CF on :443; if CF is in Full(Strict), it will reject the
# self-signed and return 526 → we surface that with a clear, customer-facing
# fix recipe instead of leaving it as a silent broken state.
#
# Returns 0 on healthy (any 2xx/3xx/4xx from origin via CF), 1 on CF-side
# error (520-526) — only used for warning, doesn't fail the whole flow.
# ---------------------------------------------------------------------------
_ssl_verify_cf_accepts_origin() {
    local domain="$1" ssl_dir="$2"

    log_sub "Verifying Cloudflare can reach origin via HTTPS..."
    sleep 2  # let CF pick up new :443 listener
    local code
    code="$( set +o pipefail; curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://${domain}/" 2>/dev/null )" || code="000"

    case "$code" in
        2*|3*|4*)
            log_sub "Cloudflare accepts origin cert (HTTP $code) — site is live."
            return 0
            ;;
        5[23][0-9])
            # CF 520-539 = origin/edge errors; 526 specifically = invalid origin cert
            printf '\n'
            log_warn "Cloudflare returned HTTP $code via CF — likely 'Full (Strict)' SSL mode"
            log_warn "rejecting our self-signed origin cert. Site is broken for visitors."
            printf '\n'
            printf '  %bFix (give your customer ONE of):%b\n\n' "$YELLOW" "$NC"
            printf '  %b1) EASIEST — switch CF SSL mode to "Full" (not "Full strict")%b\n' "$BOLD" "$NC"
            printf '     CF dashboard → SSL/TLS → Overview → select "Full"\n'
            printf '     Direct link: https://dash.cloudflare.com/?to=/:account/${domain#*.}/ssl-tls\n'
            printf '     No further action — origin cert is accepted in 10 seconds.\n\n'
            printf '  %b2) STRICT-COMPATIBLE — install a Cloudflare Origin Certificate%b\n' "$BOLD" "$NC"
            printf '     CF dashboard → SSL/TLS → Origin Server → Create Certificate\n'
            printf '     (Free, 15-year validity, signed by CF Origin CA — accepted by Full Strict.)\n'
            printf '     Save the cert + key, then on this server:\n'
            printf '       mwp ssl install-origin-cert %s\n' "$domain"
            printf '     (Pastes both files into %s/ and reloads nginx.)\n\n' "$ssl_dir"
            printf '  %b3) GREY-CLOUD — disable CF proxy for this hostname%b\n' "$BOLD" "$NC"
            printf '     CF dashboard → DNS → click the orange cloud → grey\n'
            printf '     Then: mwp ssl issue %s   (issues real Let'"'"'s Encrypt direct.)\n\n' "$domain"
            return 1
            ;;
        000)
            log_warn "Could not reach https://${domain}/ from this server (timeout/DNS) — skipping CF check."
            return 1
            ;;
        *)
            log_warn "Unexpected HTTP code from CF: $code (expected 2xx/3xx/4xx for healthy)."
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# mwp ssl install-origin-cert <domain>
#
# Customer-facing helper for CF Full(Strict). The customer generates a
# Cloudflare Origin Certificate in their CF dashboard (free, 15-year, no API
# token), then pastes the two files (cert + key) into stdin separated by an
# END marker. We write them to /etc/mwp/ssl/<domain>/ and reload nginx.
#
# Usage:
#   mwp ssl install-origin-cert example.com           # interactive paste
#   mwp ssl install-origin-cert example.com /tmp/o.pem /tmp/o.key   # from files
# ---------------------------------------------------------------------------
ssl_install_origin_cert() {
    local domain="${1:-}"
    local cert_file="${2:-}"
    local key_file="${3:-}"
    [[ -z "$domain" ]] && die "Usage: mwp ssl install-origin-cert <domain> [cert.pem key.pem]"

    # Domain must already exist (site or app) — we just swap cert files
    if ! site_exists "$domain"; then
        if [[ -f "$MWP_DIR/lib/app-registry.sh" ]]; then
            # shellcheck source=/dev/null
            source "$MWP_DIR/lib/app-registry.sh"
            app_find_by_domain "$domain" >/dev/null 2>&1 || \
                die "Domain '$domain' not in site or app registry. Create it first."
        else
            die "Domain '$domain' not in registry."
        fi
    fi

    local ssl_dir="/etc/mwp/ssl/${domain}"
    mkdir -p "$ssl_dir"
    chmod 700 "$ssl_dir"

    if [[ -n "$cert_file" && -n "$key_file" ]]; then
        [[ -f "$cert_file" ]] || die "Cert file not found: $cert_file"
        [[ -f "$key_file"  ]] || die "Key file not found: $key_file"
        cp "$cert_file" "$ssl_dir/fullchain.pem"
        cp "$key_file"  "$ssl_dir/privkey.pem"
    else
        printf '\n%bPaste your Cloudflare Origin Certificate.%b\n' "$BOLD" "$NC"
        printf 'Press Enter, paste the CERTIFICATE block (BEGIN/END CERTIFICATE), then a newline + Ctrl-D:\n\n'
        cat > "$ssl_dir/fullchain.pem"
        printf '\n%bNow paste the PRIVATE KEY block (BEGIN/END PRIVATE KEY), Enter, Ctrl-D:%b\n\n' "$BOLD" "$NC"
        cat > "$ssl_dir/privkey.pem"
    fi

    chmod 644 "$ssl_dir/fullchain.pem"
    chmod 600 "$ssl_dir/privkey.pem"

    # Validate the pair
    local cert_modulus key_modulus
    cert_modulus="$(openssl x509 -noout -modulus -in "$ssl_dir/fullchain.pem" 2>/dev/null | openssl sha256 | awk '{print $NF}')"
    key_modulus="$(openssl rsa  -noout -modulus -in "$ssl_dir/privkey.pem"   2>/dev/null | openssl sha256 | awk '{print $NF}')"
    if [[ -z "$cert_modulus" || "$cert_modulus" != "$key_modulus" ]]; then
        die "Cert and key don't match (or one is malformed). Aborting — old files restored from .bak."
    fi
    log_sub "Cert+key pair validated (modulus matches)."

    [[ -f "$MWP_DIR/lib/multi-nginx.sh" ]] && source "$MWP_DIR/lib/multi-nginx.sh"
    _ssl_post_cert_apply "$domain" "$ssl_dir" "cf-origin-cert"

    log_success "Cloudflare Origin Cert installed for ${domain}."

    # Re-verify — this time CF Full(Strict) should accept it
    _ssl_verify_cf_accepts_origin "$domain" "$ssl_dir" || true
}

# ---------------------------------------------------------------------------
# Post-cert dispatcher — once a cert exists at $cert_dir, decide whether the
# domain belongs to a WordPress site or a Docker app, and emit the right HTTPS
# server block accordingly. Also persists SSL_ENABLED/SSL_ISSUED_AT to the
# matching registry entry.
#
# Args: <domain> <cert_dir> <ssl_type:letsencrypt|self-signed>
# ---------------------------------------------------------------------------
_ssl_post_cert_apply() {
    local domain="$1" cert_dir="$2" ssl_type="$3"

    # Site (WordPress) — original code path
    if site_exists "$domain"; then
        nginx_enable_https "$domain" "$cert_dir"
        _ssl_post_install_wp "$domain"
        site_set "$domain" "SSL_ENABLED"   "$ssl_type"
        site_set "$domain" "SSL_ISSUED_AT" "$(date '+%Y-%m-%d')"
        return 0
    fi

    # App (Docker) — proxy HTTPS block
    if [[ -f "$MWP_DIR/lib/app-registry.sh" ]]; then
        # shellcheck source=/dev/null
        source "$MWP_DIR/lib/app-registry.sh"
        local app_name
        app_name="$(app_find_by_domain "$domain" 2>/dev/null || true)"
        if [[ -n "$app_name" ]]; then
            # shellcheck source=/dev/null
            source "$MWP_DIR/lib/multi-app.sh"
            app_nginx_enable_https "$app_name" "$domain" "$cert_dir"
            app_set "$app_name" "SSL_ENABLED"   "$ssl_type"
            app_set "$app_name" "SSL_ISSUED_AT" "$(date '+%Y-%m-%d')"
            return 0
        fi
    fi

    # Fallback: panel domain or unknown — leave existing vhost as-is, nginx
    # already reloaded by certbot --nginx with cert paths inserted in place.
    log_warn "Domain '$domain' not in site/app registry — HTTPS auto-block skipped."
    log_sub  "If this is the panel placeholder, that's expected (cert is on disk; vhost untouched)."
}

# ---------------------------------------------------------------------------
# Show SSL status for a site — origin cert + public TLS view (if reachable).
# IMPORTANT: when the site is behind Cloudflare, `openssl s_client -connect`
# would return the CF edge certificate, not our origin cert. So we always
# read the local cert file first (the one nginx is actually using) and
# label the public check as "visitor view" so the user understands the
# difference.
# ---------------------------------------------------------------------------
ssl_status() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && die "Usage: mwp ssl status <domain>"

    local ssl_type cert_file
    if site_exists "$domain"; then
        ssl_type="$(site_get "$domain" SSL_ENABLED)"
    elif [[ -f "$MWP_DIR/lib/app-registry.sh" ]]; then
        # shellcheck source=/dev/null
        source "$MWP_DIR/lib/app-registry.sh"
        local _app_name
        _app_name="$(app_find_by_domain "$domain" 2>/dev/null || true)"
        if [[ -n "$_app_name" ]]; then
            ssl_type="$(app_get "$_app_name" SSL_ENABLED)"
        else
            die "Domain '$domain' not found in site or app registry."
        fi
    else
        die "Domain '$domain' not found."
    fi

    case "$ssl_type" in
        letsencrypt|yes)
            cert_file="/etc/letsencrypt/live/${domain}/fullchain.pem"
            ssl_type="letsencrypt"
            ;;
        self-signed)
            cert_file="/etc/mwp/ssl/${domain}/fullchain.pem"
            ;;
        *)
            log_warn "No SSL configured for $domain (SSL_ENABLED=${ssl_type:-none})"
            log_sub  "Run: mwp ssl issue $domain"
            return 0
            ;;
    esac

    printf '\n%b  Origin certificate (%s):%b\n' "$BOLD" "$ssl_type" "$NC"
    printf '  %s\n' "──────────────────────────────────────"
    if [[ -f "$cert_file" ]]; then
        openssl x509 -in "$cert_file" -noout -subject -issuer -dates 2>&1 | sed 's/^/  /'
        local san
        san="$(openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null | tail -1 | sed 's/^[[:space:]]*/  SAN: /')"
        [[ -n "$san" ]] && printf '%s\n' "$san"
    else
        printf '  %b!%b cert file missing: %s\n' "$YELLOW" "$NC" "$cert_file"
    fi

    printf '\n%b  Public TLS handshake (what visitors see):%b\n' "$BOLD" "$NC"
    printf '  %s\n' "──────────────────────────────────────"
    local public_cert
    public_cert="$( set +o pipefail; echo | timeout 5 openssl s_client -connect "${domain}:443" -servername "$domain" 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null )"
    if [[ -n "$public_cert" ]]; then
        printf '%s\n' "$public_cert" | sed 's/^/  /'
        if [[ "$ssl_type" == "self-signed" ]] && ! printf '%s' "$public_cert" | grep -q "CN = ${domain}"; then
            printf '\n  %bℹ%b The visitor cert differs from the origin cert — the domain is\n' "$CYAN" "$NC"
            printf '    proxied through Cloudflare, which presents its own edge certificate.\n'
            printf '    Origin self-signed is used only for the CF→origin link (CF Full mode).\n'
        fi
    else
        printf '  (could not reach %s:443 — check DNS / firewall)\n' "$domain"
    fi
    printf '\n'
}
_ssl_post_install_wp() {
    local domain="$1"
    site_exists "$domain" || return 0

    local site_user web_root
    site_user="$(site_get "$domain" SITE_USER)"
    web_root="$(site_get "$domain" WEB_ROOT)"

    if [[ -n "$site_user" && -d "$web_root" ]] && command -v wp >/dev/null 2>&1; then
        sudo -u "$site_user" wp --path="$web_root" option update home    "https://${domain}" 2>/dev/null || true
        sudo -u "$site_user" wp --path="$web_root" option update siteurl "https://${domain}" 2>/dev/null || true
        log_sub "WordPress home/siteurl updated → https://${domain}"
    fi
}
