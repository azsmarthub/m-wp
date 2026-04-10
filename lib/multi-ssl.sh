#!/usr/bin/env bash
# lib/multi-ssl.sh — SSL management for mwp

[[ -n "${_MWP_SSL_LOADED:-}" ]] && return 0
_MWP_SSL_LOADED=1

# ---------------------------------------------------------------------------
# Issue Let's Encrypt certificate for a site
# ---------------------------------------------------------------------------
ssl_issue() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && die "Usage: mwp ssl issue <domain>"

    command -v certbot >/dev/null 2>&1 || die "Certbot not found. Run install.sh first."

    # Remove stale accounts that cause "Account not found" errors
    rm -rf /etc/letsencrypt/accounts/ 2>/dev/null || true

    # Detect if www subdomain has DNS pointing to this server.
    # If not, requesting it would (a) waste an LE rate-limit attempt and
    # (b) modify the cert SAN list — making the next renewal fail too.
    local server_ip www_ip include_www=0
    server_ip="$(server_get "SERVER_IP")"
    www_ip="$( set +o pipefail; dig +short "www.${domain}" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -1 )"
    if [[ -n "$server_ip" && -n "$www_ip" && "$www_ip" == "$server_ip" ]]; then
        include_www=1
        log_sub "www.${domain} DNS resolves here too — including in cert"
    else
        log_sub "www.${domain} DNS not pointing here (skipping to save LE rate limit)"
    fi

    local certbot_args=(
        certbot certonly --nginx --non-interactive --agree-tos
        --email "admin@${domain}" -d "$domain"
    )
    [[ $include_www -eq 1 ]] && certbot_args+=( -d "www.${domain}" )

    log_sub "Requesting certificate for ${domain}..."
    if ! "${certbot_args[@]}" 2>&1 | tail -10; then
        die "Certbot failed. Check DNS propagation and retry: mwp ssl issue $domain"
    fi

    # Update Nginx vhost with HTTPS block
    [[ -f "$MWP_DIR/lib/multi-nginx.sh" ]] && source "$MWP_DIR/lib/multi-nginx.sh"
    nginx_enable_https "$domain"

    # Update WordPress siteurl/home to https (only if site is registered)
    if site_exists "$domain"; then
        local site_user web_root
        site_user="$(site_get "$domain" SITE_USER)"
        web_root="$(site_get "$domain" WEB_ROOT)"
        if [[ -n "$site_user" && -d "$web_root" ]] && command -v wp >/dev/null 2>&1; then
            sudo -u "$site_user" wp --path="$web_root" option update home "https://${domain}" 2>/dev/null || true
            sudo -u "$site_user" wp --path="$web_root" option update siteurl "https://${domain}" 2>/dev/null || true
            log_sub "WordPress home/siteurl updated → https://${domain}"
        fi
    fi

    # Update registry
    site_set "$domain" "SSL_ENABLED" "yes"
    site_set "$domain" "SSL_ISSUED_AT" "$(date '+%Y-%m-%d')"

    # Auto-renewal cron (if not already set up by certbot)
    if [[ ! -f /etc/cron.d/certbot ]]; then
        printf '0 3 * * * root certbot renew --quiet --post-hook "systemctl reload nginx"\n' \
            > /etc/cron.d/mwp-certbot-renew
        chmod 644 /etc/cron.d/mwp-certbot-renew
    fi

    log_success "SSL issued for ${domain}"
}
