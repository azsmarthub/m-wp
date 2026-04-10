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

    log_sub "Requesting certificate for ${domain} (and www.${domain})..."
    certbot certonly \
        --nginx \
        --non-interactive \
        --agree-tos \
        --email "admin@${domain}" \
        -d "$domain" \
        -d "www.${domain}" \
        --redirect 2>&1 | tail -5 || \
    certbot certonly \
        --nginx \
        --non-interactive \
        --agree-tos \
        --email "admin@${domain}" \
        -d "$domain" \
        --redirect 2>&1 | tail -5 || \
        die "Certbot failed. Check DNS propagation and retry: mwp ssl issue $domain"

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
