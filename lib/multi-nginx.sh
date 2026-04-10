#!/usr/bin/env bash
# lib/multi-nginx.sh — Per-site Nginx management for mwp

[[ -n "${_MWP_NGINX_LOADED:-}" ]] && return 0
_MWP_NGINX_LOADED=1

NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
NGINX_MWP_SNIPPETS="/etc/nginx/mwp"

# ---------------------------------------------------------------------------
# Guard: verify install.sh was run (sites-enabled must exist)
# ---------------------------------------------------------------------------
nginx_check_setup() {
    [[ -d "$NGINX_SITES_AVAILABLE" && -d "$NGINX_SITES_ENABLED" ]] || \
        die "Nginx not configured for multi-site. Run install.sh first."
    grep -q "sites-enabled" /etc/nginx/nginx.conf 2>/dev/null || \
        die "nginx.conf missing sites-enabled include. Run install.sh first."
}

# ---------------------------------------------------------------------------
# Create Nginx vhost for a site
# Expects: DOMAIN, SITE_USER, PHP_VERSION, WEB_ROOT, CACHE_PATH (from env)
# ---------------------------------------------------------------------------
nginx_create_site() {
    local domain="$1"
    nginx_check_setup

    local conf_file="$NGINX_SITES_AVAILABLE/${domain}.conf"
    GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S')" \
    render_template "$MWP_DIR/templates/nginx/multi-site.conf.tpl" > "$conf_file"

    # Symlink without reload — restart will pick up vhost AND new group membership
    ln -sf "$conf_file" "$NGINX_SITES_ENABLED/${domain}.conf"

    # IMPORTANT: full restart, not reload.
    # _site_create_user just ran `usermod -aG <slug> www-data` to add www-data
    # to the new site group. SIGHUP (reload) does NOT re-evaluate supplementary
    # groups of the master process — only a fresh start does. Without restart,
    # nginx workers can't read static files in /home/<slug>/<domain>/ (chmod 750)
    # and serve 403 for CSS/JS/images.
    nginx_test
    systemctl restart nginx || die "nginx restart failed"
    log_sub "Nginx vhost created + restarted: $conf_file"
}

# ---------------------------------------------------------------------------
# Enable site (symlink)
# ---------------------------------------------------------------------------
nginx_enable_site() {
    local domain="$1"
    local src="$NGINX_SITES_AVAILABLE/${domain}.conf"
    local dst="$NGINX_SITES_ENABLED/${domain}.conf"

    [[ -f "$src" ]] || die "Nginx config not found: $src"
    ln -sf "$src" "$dst"
    nginx_reload
    log_sub "Nginx site enabled: $domain"
}

# ---------------------------------------------------------------------------
# Disable site (remove symlink, keep config)
# ---------------------------------------------------------------------------
nginx_disable_site() {
    local domain="$1"
    local dst="$NGINX_SITES_ENABLED/${domain}.conf"

    rm -f "$dst"
    nginx_reload
    log_sub "Nginx site disabled: $domain"
}

# ---------------------------------------------------------------------------
# Delete site config entirely
# ---------------------------------------------------------------------------
nginx_delete_site() {
    local domain="$1"

    rm -f "$NGINX_SITES_ENABLED/${domain}.conf"
    rm -f "$NGINX_SITES_AVAILABLE/${domain}.conf"
    nginx_reload
    log_sub "Nginx vhost removed: $domain"
}

# ---------------------------------------------------------------------------
# Enable HTTPS redirect in vhost (after SSL issued)
# ---------------------------------------------------------------------------
nginx_enable_https() {
    local domain="$1"
    local conf="$NGINX_SITES_AVAILABLE/${domain}.conf"

    [[ -f "$conf" ]] || die "Nginx config not found for $domain"

    # Uncomment the return 301 line, comment out the placeholder comment
    sed -i 's|# return 301 https://\$host\$request_uri;|return 301 https://$host$request_uri;|' "$conf"

    # Add HTTPS server block if not present
    if ! grep -q "listen 443" "$conf"; then
        local site_user php_version web_root cache_path
        site_user="$(site_get "$domain" SITE_USER)"
        php_version="$(site_get "$domain" PHP_VERSION)"
        web_root="$(site_get "$domain" WEB_ROOT)"
        cache_path="$(site_get "$domain" CACHE_PATH)"

        cat >> "$conf" <<HTTPS_BLOCK

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${domain} www.${domain};

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    add_header Strict-Transport-Security "max-age=63072000" always;

    root ${web_root};
    index index.php index.html;

    access_log /home/${site_user}/logs/nginx-access.log;
    error_log  /home/${site_user}/logs/nginx-error.log warn;

    set \$skip_cache 0;
    if (\$request_method = POST) { set \$skip_cache 1; }
    if (\$query_string != "") { set \$skip_cache 1; }
    if (\$request_uri ~* "(/wp-admin/|/xmlrpc.php|/wp-cron.php|wp-login.php|\?preview=)") { set \$skip_cache 1; }
    if (\$http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_no_cache|wordpress_logged_in") { set \$skip_cache 1; }

    location / { try_files \$uri \$uri/ /index.php?\$args; }

    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php${php_version}-fpm-${site_user}.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;

        fastcgi_cache ${site_user}_cache;
        fastcgi_cache_valid 200 301 302 60m;
        fastcgi_cache_use_stale error timeout updating invalid_header http_500 http_503;
        fastcgi_cache_background_update on;
        fastcgi_cache_lock on;
        fastcgi_cache_bypass \$skip_cache;
        fastcgi_no_cache \$skip_cache;
        add_header X-FastCGI-Cache \$upstream_cache_status;

        fastcgi_read_timeout 300;
    }

    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot|webp|avif)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt  { allow all; log_not_found off; access_log off; }
    location ~* /\.(ht|git|svn|env) { deny all; }
    location ~* /(wp-config\.php|xmlrpc\.php) { deny all; }
}
HTTPS_BLOCK
    fi

    nginx_reload
    log_sub "HTTPS enabled for $domain"
}

# ---------------------------------------------------------------------------
# Test + reload
# ---------------------------------------------------------------------------
nginx_test() {
    nginx -t 2>/dev/null || die "Nginx config test failed. Run: nginx -t"
}

nginx_reload() {
    nginx_test
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
}

# ---------------------------------------------------------------------------
# Purge FastCGI cache for a site
# ---------------------------------------------------------------------------
cache_purge_site() {
    local domain="$1"
    local cache_path
    cache_path="$(site_get "$domain" CACHE_PATH)"

    if [[ -d "$cache_path" ]]; then
        local count
        count="$(find "$cache_path" -type f 2>/dev/null | wc -l)"
        rm -rf "${cache_path:?}"/* 2>/dev/null || true
        log_success "FastCGI cache purged: $count files removed ($domain)"
    else
        log_warn "Cache path not found: $cache_path"
    fi

    # Also flush Redis DB for this site
    local redis_db redis_sock
    redis_db="$(site_get "$domain" REDIS_DB)"
    redis_sock="$(server_get "REDIS_SOCK")"
    redis_sock="${redis_sock:-/run/redis/redis-server.sock}"

    if [[ -n "$redis_db" ]] && command -v redis-cli >/dev/null 2>&1; then
        redis-cli -s "$redis_sock" -n "$redis_db" FLUSHDB >/dev/null 2>&1 || true
        log_sub "Redis DB $redis_db flushed ($domain)"
    fi
}
