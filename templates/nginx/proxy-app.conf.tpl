# mwp — Nginx reverse proxy for app '{{APP_NAME}}'
# Generated: {{GENERATED_AT}}
# Domain:    {{DOMAIN}}
# Container: mwp-{{APP_NAME}} (bound to 127.0.0.1:{{HOST_PORT}})

upstream mwp_app_{{APP_NAME}} {
    server 127.0.0.1:{{HOST_PORT}};
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name {{DOMAIN}};

    # Redirect to HTTPS (uncommented after SSL issued)
    # return 301 https://$host$request_uri;

    access_log /var/log/nginx/mwp-app-{{APP_NAME}}-access.log;
    error_log  /var/log/nginx/mwp-app-{{APP_NAME}}-error.log warn;

    # Generous body size — n8n binary uploads, Next.js large requests, etc.
    client_max_body_size 100M;

    # NOTE: ACME http-01 challenge is handled dynamically by certbot --nginx
    # (it injects a temporary location at issue time). Don't add an explicit
    # /.well-known/acme-challenge/ block here — it would override certbot's
    # injection and break validation.

    location / {
        proxy_pass http://mwp_app_{{APP_NAME}};
        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;

        # WebSocket upgrade (n8n, Next.js HMR, live dashboards)
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        # Streaming-friendly: SSE, log tails, long polling
        proxy_buffering off;
        proxy_cache off;

        # Long-lived requests (workflow runs, build streams)
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
    }
}
