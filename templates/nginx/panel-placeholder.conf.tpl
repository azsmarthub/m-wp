# mwp — Panel management vhost
# Domain: {{PANEL_DOMAIN}}
# Generated: {{GENERATED_AT}}
# Purpose: Reserved for mwp web UI (future). Currently shows status page.

server {
    listen 80;
    listen [::]:80;
    server_name {{PANEL_DOMAIN}};

    # Redirect to HTTPS when SSL is issued
    # return 301 https://$host$request_uri;

    root /var/www/mwp-panel;
    index index.html;

    # Restrict access to this server's IP and trusted IPs only
    # Uncomment and set your IP:
    # allow YOUR_IP;
    # deny all;

    location / {
        try_files $uri $uri/ =404;
    }

    access_log /var/log/nginx/mwp-panel-access.log;
    error_log  /var/log/nginx/mwp-panel-error.log warn;
}
