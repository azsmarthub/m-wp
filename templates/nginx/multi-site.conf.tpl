# mwp — Nginx vhost for {{DOMAIN}}
# Generated: {{GENERATED_AT}}
# Site user: {{SITE_USER}}

fastcgi_cache_path {{CACHE_PATH}}
    levels=1:2
    keys_zone={{SITE_USER}}_cache:10m
    max_size=1g
    inactive=60m
    use_temp_path=off;

server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}} www.{{DOMAIN}};

    # Redirect to HTTPS (activated after SSL issued)
    # return 301 https://$host$request_uri;

    root {{WEB_ROOT}};
    index index.php index.html;

    access_log /home/{{SITE_USER}}/logs/nginx-access.log;
    error_log  /home/{{SITE_USER}}/logs/nginx-error.log warn;

    # FastCGI cache settings
    set $skip_cache 0;

    # Skip cache: POST requests
    if ($request_method = POST) { set $skip_cache 1; }

    # Skip cache: query string
    if ($query_string != "") { set $skip_cache 1; }

    # Skip cache: wp-admin, login, cron, preview
    if ($request_uri ~* "(/wp-admin/|/xmlrpc.php|/wp-cron.php|wp-login.php|\?preview=)") {
        set $skip_cache 1;
    }

    # Skip cache: logged-in users & recent commenters
    if ($http_cookie ~* "comment_author|wordpress_[a-f0-9]+|wp-postpass|wordpress_no_cache|wordpress_logged_in") {
        set $skip_cache 1;
    }

    # Skip cache: WooCommerce
    if ($request_uri ~* "(/cart/|/checkout/|/my-account/)") { set $skip_cache 1; }
    if ($http_cookie ~* "(woocommerce_cart_hash|woocommerce_items_in_cart|wp_woocommerce_session)") {
        set $skip_cache 1;
    }

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php{{PHP_VERSION}}-fpm-{{SITE_USER}}.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;

        fastcgi_cache {{SITE_USER}}_cache;
        fastcgi_cache_valid 200 301 302 60m;
        fastcgi_cache_use_stale error timeout updating invalid_header http_500 http_503;
        fastcgi_cache_background_update on;
        fastcgi_cache_lock on;
        fastcgi_cache_bypass $skip_cache;
        fastcgi_no_cache $skip_cache;
        add_header X-FastCGI-Cache $upstream_cache_status;

        fastcgi_read_timeout 300;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
    }

    # Static assets — long cache, no logging
    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot|webp|avif)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
        log_not_found off;
    }

    # Security
    location = /favicon.ico { log_not_found off; access_log off; }
    location = /robots.txt  { allow all; log_not_found off; access_log off; }
    location ~* /\.(ht|git|svn|env) { deny all; }
    location ~* /(wp-config\.php|xmlrpc\.php) { deny all; }

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript
               application/rss+xml application/atom+xml image/svg+xml;
}
