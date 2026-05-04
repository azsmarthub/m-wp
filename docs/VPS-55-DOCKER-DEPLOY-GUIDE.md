# VPS .55 — Docker Deploy Guide cho dự án mới

> **Mục đích file này**: Cung cấp đầy đủ context cho AI agent (và human ops) **deploy 1 dự án Docker mới lên VPS `62.146.232.55`** mà KHÔNG ảnh hưởng các app/site đang chạy. Đọc xong file này, bất kỳ AI nào cũng phải hiểu kiến trúc + convention của VPS để không "đạp lên" cấu hình hiện hữu.
>
> **VPS**: `62.146.232.55` (Ubuntu 24.04, hostname mwp)
> **Project quản lý**: `~/projects/m-wp` — CLI `mwp` chạy bằng Bash thuần
> **SSH**: `ssh -i ~/.ssh/azsmarthub_shared root@62.146.232.55`
> **Last updated**: 2026-05-04

---

## 1. KIẾN TRÚC VPS — TỔNG QUAN

VPS này có **3 layer chạy song song**, mỗi layer dùng port + namespace khác nhau:

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer A — mwp (Multi WordPress)                                │
│  ~30 WP sites, mỗi site = (Linux user) + (PHP-FPM 8.3 pool) +   │
│  (MariaDB DB) + (nginx vhost). Quản lý qua `mwp` CLI.           │
│  KHÔNG đụng đến lớp này — sửa tay sẽ phá registry.              │
├─────────────────────────────────────────────────────────────────┤
│  Layer B — Bare Laravel (gpm2)                                  │
│  Linux user `gpm2` + PHP-FPM 8.3 pool riêng + MariaDB DB +      │
│  nginx vhost + LE cert. Cùng pattern WP nhưng KHÔNG mwp-managed.│
├─────────────────────────────────────────────────────────────────┤
│  Layer C — Docker apps                                          │
│  Mỗi app = (compose stack) + (nginx vhost host-level proxy) +   │
│  (LE cert). Container bind 127.0.0.1:<port>, host nginx proxy.  │
│  Hiện có: gpm-docker, n8n, discord-bot, media-service, mwp-pgadmin │
└─────────────────────────────────────────────────────────────────┘

Shared services (host-level, dùng chung mọi layer):
  • nginx              (host, port 80/443)
  • MariaDB 11.4       (host, port 3306, root pass ở /etc/mwp/server.conf)
  • PostgreSQL 16      (host, port 5432, listen *, pg_hba allow 172.16.0.0/12)
  • Docker engine      (cài sẵn qua mwp docker install)
  • certbot (LE)       (auto-renew via certbot.timer)
  • mwp-pgadmin        (Docker container, vhost pgadmin.azsmarthub.com)
```

**Resource snapshot (2026-05-04)**:
- 6 vCPU, 12 GB RAM (đang dùng ~3 GB), Swap 1 GB unused
- Disk 96 GB, **đã dùng 59%** ← điểm yếu nhất, monitor trước mỗi deploy lớn
- Load avg ~1.2 (rất thấp), TCP estab ~12

---

## 2. NHỮNG GÌ ĐÃ CÓ — KHÔNG ĐƯỢC PHÁ

### 2.1. mwp-managed sites (Layer A)

Quản lý qua `mwp` CLI (`~/projects/m-wp` → cài tại `/opt/m-wp/`). State trong:
- `/etc/mwp/sites/` — per-site config
- `/etc/mwp/server.conf` — server-wide config (chứa `DB_ROOT_PASS`)
- `/etc/mwp/apps/` — non-WP app registry (Docker apps cũng track ở đây nếu deploy qua mwp)
- `/var/lib/mwp/` — data (apps, ssl, logs)

**Pool naming**: `<user>_<domain_underscored>.conf` (vd `affcms_azsmarthub_com.conf`)
Sockets: `/run/php/php8.3-fpm-<user>.sock`

**TUYỆT ĐỐI KHÔNG**:
- Sửa tay file trong `/etc/php/8.3/fpm/pool.d/*` (mwp regenerate)
- Sửa tay vhost mwp-managed trong `/etc/nginx/sites-available/`
- Tạo Linux user trùng tên với mwp site (sẽ vỡ ownership)
- `mariadb -uroot` rồi DROP DATABASE bất kỳ tên `wp_*` (đó là WP sites)

### 2.2. Bare Laravel (gpm2)

Pattern giống WP nhưng tự manage (không qua mwp):
- User `gpm2`, home `/home/gpm2/`
- Pool `/etc/php/8.3/fpm/pool.d/gpm2.conf`
- Vhost `/etc/nginx/sites-available/gpm2.azsmarthub.com.conf`
- DB `gpm2_login` (MariaDB)
- LE cert `/etc/letsencrypt/live/gpm2.azsmarthub.com/`

### 2.3. Docker stacks đang chạy

| App | Compose dir | Container name | Port (host) | Vhost | Notes |
|---|---|---|---|---|---|
| **gpm-docker** | `/home/gpm-docker/` | `gpm_login_global_private_server_*` | 127.0.0.1:8080 (web), 8082 (pma) | `gpm.azsmarthub.com` | Image chính chủ ngochoaitn/, internal MySQL container |
| **n8n** | `/home/n8n/` | `n8n` | host-mode/socket | `n8n.azsmarthub.com` | Có `n8n_runner` task subprocess (~480MB RAM) |
| **discord-bot** | `/home/discord-bot/` | `discord-bot` | 127.0.0.1:3044 (internal only) | (none) | Không expose public |
| **media-service** | `/home/media-service/` | `media-backend`, `media-frontend` | 127.0.0.1:8011, 8012 | `media.msyen.com` | FastAPI + React, dùng host postgres |
| **mwp-pgadmin** | (mwp-managed) | `mwp-pgadmin` | 127.0.0.1:10000 | `pgadmin.azsmarthub.com` | image dpage/pgadmin4, mount `/var/lib/mwp/apps/pgadmin/data` |

**Docker engine state**: `mwp docker install` đã cài. Daemon configured. Networks default `bridge` + per-stack custom networks.

---

## 3. CONVENTION BẮT BUỘC CHO DOCKER APP MỚI

### 3.1. Compose file — checklist

```yaml
services:
  myapp-web:
    image: ...                          # hoặc build:
    container_name: myapp-web           # ✅ tên rõ ràng, prefix bằng tên app
    restart: unless-stopped             # ✅ luôn

    ports:
      - "127.0.0.1:8XXX:80"             # ✅ BẮT BUỘC bind 127.0.0.1, KHÔNG 0.0.0.0
                                        # ✅ Pick port chưa dùng (xem mục 3.2)

    environment:
      # Nếu cần connect host postgres:
      - DATABASE_URL=postgresql://USER:PASS@host.docker.internal:5432/DB

    extra_hosts:
      - "host.docker.internal:host-gateway"   # ✅ BẮT BUỘC nếu connect host service

    volumes:
      - ./data:/app/data                # ✅ Bind mount relative — KHÔNG dùng /var/...
                                        # Nếu cần named volume: tên prefix bằng app

    networks:
      - myapp-net                       # ✅ Own network, KHÔNG external/shared

    healthcheck:                        # ✅ Khuyến nghị có
      test: [...]
      interval: 30s
      start_period: 30s

networks:
  myapp-net:                            # ✅ Tự define, đừng dùng external: true
    driver: bridge
```

### 3.2. Port allocation — đã dùng

| Port | Owner |
|---|---|
| 80, 443 | host nginx (KHÔNG container nào được listen 0.0.0.0:80/443) |
| 3306 | MariaDB host |
| 5432 | PostgreSQL host |
| 6379 | Redis host (nếu mwp redis cài) |
| 8080 | gpm-docker web |
| 8082 | gpm-docker phpmyadmin |
| 8011 | media-backend |
| 8012 | media-frontend |
| 10000 | mwp-pgadmin |
| 3044 | discord-bot |

→ **App mới nên pick port `8020-8099` hoặc `9000-9999`** để tránh xung đột tương lai.

### 3.3. Network — đừng share

❌ **KHÔNG** dùng `networks: { default: { external: true, name: n8n_default } }` kiểu compose từ VPS .156.
Trên .55 không có shared network "n8n_default" và mỗi app phải tự-cô-lập.

✅ **NÊN** tự define network riêng `myapp-net`. Nếu app cần connect host service (postgres, mariadb, redis, nginx hosted), dùng `host.docker.internal` qua `extra_hosts: host-gateway`.

### 3.4. Volumes & disk

- Bind mount: relative path trong compose dir (`./data`, `./logs`) — gọn, dễ backup
- Named volume: prefix bằng tên app để tránh đụng (`myapp_db_data` chứ không `db_data`)
- **KIỂM TRA disk trước**: `df -h /` — nếu >75% thì cảnh báo user trước khi pull large images
- Image lớn (>500MB) nên `docker compose pull` trước, để user xem disk impact

---

## 4. SSL & nginx vhost — PATTERN CHUẨN

Mọi public-facing app dùng **CF orange cloud + LE cert + host nginx proxy**:

```
[Browser] ──HTTPS──> [Cloudflare Edge] ──HTTPS──> [host nginx :443]
                                                          │
                                                          └──proxy──> [Container 127.0.0.1:8XXX]
```

### 4.1. DNS

- A record domain → `62.146.232.55` (hoặc IPv6 `2a02:c206:...`)
- **CF orange cloud ON** (proxy mode) — required cho edge cache, DDoS protection
- CF SSL/TLS mode: **Full (strict)** (vì origin có cert thật từ LE)

### 4.2. Issue LE cert (HTTP-01 webroot)

```bash
# Step 1: Tạo HTTP-only vhost tạm để webroot challenge work
cat > /etc/nginx/sites-available/myapp.example.com.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name myapp.example.com;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme-challenge;
        default_type "text/plain";
        try_files \$uri =404;
    }
    location / {
        return 503 "deployment in progress\n";
    }
}
EOF
ln -sf /etc/nginx/sites-available/myapp.example.com.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# Step 2: Issue cert (CF orange cloud cho phép ACME challenge mặc định)
certbot certonly --webroot -w /var/www/acme-challenge \
  -d myapp.example.com \
  --email duongnv.hl@gmail.com --agree-tos --non-interactive

# Step 3: Replace vhost với HTTPS version (xem template 4.3)
```

### 4.3. nginx vhost template (HTTPS proxy → container)

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name myapp.example.com;
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme-challenge;
        default_type "text/plain";
        try_files $uri =404;
    }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name myapp.example.com;

    ssl_certificate     /etc/letsencrypt/live/myapp.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/myapp.example.com/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    access_log /var/log/nginx/myapp-access.log;
    error_log  /var/log/nginx/myapp-error.log warn;

    client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:8XXX;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_read_timeout 300s;
        proxy_buffering off;
    }
}
```

### 4.4. Validate + reload — LUÔN

```bash
nginx -t                            # ⚠️ BẮT BUỘC trước reload
systemctl reload nginx              # graceful — không drop existing connections
# ⚠️ Restart (KHÔNG reload) chỉ khi:
#    - Đổi user/group nginx (group changes cần process mới)
#    - Đổi worker_processes / worker_connections
```

---

## 5. DATABASE — pattern theo loại

### 5.1. Postgres (host install)

App Docker connect host postgres qua `host.docker.internal:5432`.

**Tạo user + DB cho app mới**:
```bash
ssh root@.55 'sudo -u postgres psql' <<SQL
CREATE USER myapp_user WITH PASSWORD 'GEN_RAND_PASS_32CHARS';
CREATE DATABASE myapp_db OWNER myapp_user;
GRANT ALL PRIVILEGES ON DATABASE myapp_db TO myapp_user;
\c myapp_db
GRANT ALL ON SCHEMA public TO myapp_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO myapp_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO myapp_user;
REVOKE ALL ON DATABASE myapp_db FROM PUBLIC;
SQL
```

`pg_hba.conf` đã allow `172.16.0.0/12` (Docker bridges) + `127.0.0.1` → KHÔNG cần đụng.

**Quản lý qua mwp** (recommended): `mwp pg db-create myapp` lưu cred vào `/etc/mwp/pg-dbs/myapp.conf` mode 600. (Lib `multi-postgres.sh`).

### 5.2. MariaDB (host install)

Root pass ở `/etc/mwp/server.conf` (`DB_ROOT_PASS=...`).

```bash
DB_ROOT_PASS=$(grep ^DB_ROOT_PASS /etc/mwp/server.conf | cut -d= -f2)
mariadb -uroot -p"$DB_ROOT_PASS" <<SQL
CREATE DATABASE myapp_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'myapp_user'@'localhost' IDENTIFIED BY 'GEN_RAND_PASS';
GRANT ALL PRIVILEGES ON myapp_db.* TO 'myapp_user'@'localhost';
FLUSH PRIVILEGES;
SQL
```

**Lưu ý mwp Redis DB limit**: nếu app dùng Redis qua mwp setup, hardcoded `seq 0 15` (16 DB max). Bump 16→128 BEFORE creating site 17. Xem `~/.claude/projects/.../memory/feedback_mwp_redis_db_limit.md`.

### 5.3. Internal DB (DB chạy trong container)

Pattern này OK cho app self-contained (vd `gpm-docker` có MySQL container riêng). Nhưng:
- Volume name phải prefix app (`myapp_db_data`, không phải `db_data`)
- Backup khó hơn — phải `docker exec mysqldump` rồi tar
- Không share được giữa các app

→ **Chỉ dùng khi**: app đến từ image chính chủ đã có sẵn pattern này, hoặc có lý do isolation cụ thể.

---

## 6. PERMISSIONS — gotcha hay gặp

### 6.1. www-data và group ownership

Khi container expose port `127.0.0.1:8XXX` và host nginx (`www-data`) proxy đến → KHÔNG cần www-data có quyền filesystem (vì proxy qua TCP, không stat file).

Nhưng nếu host nginx serve static từ `/home/<user>/...` (vd Laravel public dir) → www-data **PHẢI** trong group của user:

```bash
usermod -a -G myappuser www-data
systemctl restart nginx           # ⚠️ RESTART, không reload — group cần process mới
```

### 6.2. Container user

Tránh image chạy root nếu có thể (security). Khi bind mount, ID inside container phải khớp file owner trên host. Pattern an toàn:

```yaml
volumes:
  - ./data:/app/data
user: "1000:1000"   # explicit, không assume
```

---

## 7. CHECKLIST DEPLOY APP MỚI

```
☐ 1. Disk check: df -h /  (nếu >75% → cảnh báo user)
☐ 2. Pull image / build trước → xác định size, fail sớm
☐ 3. Pick port chưa dùng (xem mục 3.2)
☐ 4. Compose: bind 127.0.0.1, own network, container_name rõ ràng
☐ 5. Nếu cần host DB: tạo user/DB + extra_hosts host.docker.internal
☐ 6. docker compose up -d → wait healthy
☐ 7. Test internal: curl http://127.0.0.1:8XXX/health
☐ 8. DNS A record → 62.146.232.55, CF orange cloud ON
☐ 9. Tạo HTTP-only vhost cho ACME → certbot issue → swap full HTTPS vhost
☐ 10. nginx -t → systemctl reload nginx
☐ 11. Test public: curl https://myapp.example.com/health (qua DNS thật)
☐ 12. Test các site khác KHÔNG bị ảnh hưởng (curl --resolve các domain quan trọng)
☐ 13. Lưu credentials: /root/<app>-creds-YYYY-MM-DD.txt mode 600
        + mirror local ~/projects/ssh-vps-all/credentials/
☐ 14. Document trong memory: ~/.claude/projects/.../memory/project_<app>.md
        + thêm dòng vào MEMORY.md
```

---

## 8. NHỮNG PITFALL ĐÃ TRẢ GIÁ — GHI ĐỂ KHÔNG MẮC LẠI

### 8.1. nginx group changes cần RESTART (không reload)
`usermod -a -G newgroup www-data` không có hiệu lực với worker đang chạy. `systemctl reload nginx` chỉ re-read config, KHÔNG re-evaluate group memberships. Phải `systemctl restart nginx`.

### 8.2. nginx location order — regex first match wins
Khi có nhiều regex location match cùng URI, **first declared wins** (không phải longest-match). Ví dụ Laravel subdir pattern:
```nginx
# ❌ SAI — try_files internal redirect cycle, serve PHP source
location ~ ^/public/ { try_files $uri /public/index.php; }
location ~ \.php$   { fastcgi_pass ...; }

# ✅ ĐÚNG — .php location declared trước
location ~ ^/public/.*\.php$ { fastcgi_pass ...; }
location ~ ^/public/         { try_files $uri /public/index.php; }
```

### 8.3. Container không có thư viện Python `passlib`
Nếu cần hash bcrypt password cho seed user, dùng `bcrypt` lib trực tiếp:
```bash
docker exec myapp-backend python -c 'import bcrypt; print(bcrypt.hashpw(b"PASS", bcrypt.gensalt()).decode())'
```
KHÔNG dùng `from passlib.context import CryptContext` — nhiều container không cài, sẽ silently fail và lưu hash rỗng vào DB.

### 8.4. CF Origin cert vs LE cert
- **CF Origin cert** (ở `/etc/ssl/cloudflare/origin-azsmarthub.{pem,key}`, valid 2040, SAN `*.azsmarthub.com`): chỉ valid khi traffic qua CF middle. Tắt CF orange cloud = broken.
- **LE cert**: valid universally. Recommended cho mọi app mới (giúp test direct origin, fallback nếu CF down).

### 8.5. CF cache stale
Sau khi setup nginx vhost mới, CF có thể cache "page cũ" (vd CF default error page) nếu domain đã point tới CF từ trước. Nếu user thấy nội dung sai → bypass cache với `?nocache=$(date +%s)` để verify origin, rồi purge CF cache zone.

### 8.6. Contabo DNS unreliable
Nếu `apt update` / pull image fail DNS → check `/etc/systemd/resolved.conf` upstream. Override:
```
[Resolve]
DNS=1.1.1.1 8.8.8.8 9.9.9.9
```
Xem feedback memory `feedback_contabo_dns_unreliable.md`.

### 8.7. nginx underscores_in_headers
Default `off` — header với `_` bị strip. Set `underscores_in_headers on;` trong http block nếu app gửi/nhận header non-standard. Memory `feedback_nginx_underscores_in_headers.md`.

---

## 9. WHERE THINGS LIVE — quick map

| Thứ | Đường dẫn |
|---|---|
| mwp CLI source (host) | `/opt/m-wp/` (clone từ `~/projects/m-wp`) |
| mwp config | `/etc/mwp/` (server.conf, sites/, apps/, ssl/, pg-dbs/) |
| mwp data | `/var/lib/mwp/` |
| nginx vhost | `/etc/nginx/sites-available/` (enable qua symlink trong `sites-enabled/`) |
| LE certs | `/etc/letsencrypt/live/<domain>/` |
| CF Origin cert | `/etc/ssl/cloudflare/origin-azsmarthub.{pem,key}` |
| ACME webroot | `/var/www/acme-challenge/` |
| MariaDB root pass | `/etc/mwp/server.conf` → `DB_ROOT_PASS=...` |
| Postgres superuser | `postgres` (peer auth, `sudo -u postgres psql`) |
| Per-app pg creds | `/etc/mwp/pg-dbs/<name>.conf` (mode 600) |
| Docker compose dirs | `/home/<app>/` (vd `/home/n8n/`, `/home/media-service/`) |
| App credentials (host) | `/root/<app>-creds-YYYY-MM-DD.txt` (mode 600) |
| App credentials (local mirror) | `~/projects/ssh-vps-all/credentials/<app>-creds-YYYYMMDD.txt` |
| Project memory | `~/.claude/projects/-home-azsmarthub-projects-ssh-vps-all/memory/` |

---

## 10. QUICK COMMANDS

```bash
# SSH
ssh -i ~/.ssh/azsmarthub_shared root@62.146.232.55

# Disk + load snapshot
ssh root@.55 'df -h /; free -h; uptime; docker stats --no-stream'

# Test site through real DNS (from local)
curl -sk -o /dev/null -w "HTTP %{http_code} ip=%{remote_ip}\n" https://myapp.example.com/

# Test site origin direct (bypass CF, from .55)
ssh root@.55 'curl -sk -o /dev/null -w "%{http_code}\n" --resolve myapp.example.com:443:127.0.0.1 https://myapp.example.com/'

# nginx validate + reload
ssh root@.55 'nginx -t && systemctl reload nginx'

# Container logs
ssh root@.55 'docker logs <container> --tail 50 -f'

# Restart 1 stack without affecting others
ssh root@.55 'cd /home/<app> && docker compose restart'

# MariaDB shell (uses root pass from mwp config)
ssh root@.55 'DB_ROOT_PASS=$(grep ^DB_ROOT_PASS /etc/mwp/server.conf | cut -d= -f2); mariadb -uroot -p"$DB_ROOT_PASS"'

# Postgres shell
ssh root@.55 'sudo -u postgres psql'

# LE renew dry-run for 1 cert
ssh root@.55 'certbot renew --cert-name myapp.example.com --dry-run'
```

---

## 11. KHI BẠN LÀ AI — DO / DON'T

### ✅ DO
- **Đọc memory trước**: `~/.claude/projects/-home-azsmarthub-projects-ssh-vps-all/memory/MEMORY.md` có index các project memory đã ghi
- **Verify state hiện tại** trước khi assume — memory có thể stale
- **`nginx -t` trước reload**, **dry-run certbot** trước issue thật
- **Bind container ports 127.0.0.1** mọi lúc
- **Test các site khác** sau mỗi thay đổi nginx (curl --resolve)
- **Document credentials** vào 2 nơi (VPS + local mirror)
- **Update memory** sau khi deploy xong

### ❌ DON'T
- KHÔNG sửa tay file mwp-managed (`/etc/mwp/`, `/etc/php/8.3/fpm/pool.d/<wp-site>.conf`, vhost WP)
- KHÔNG dùng external network `n8n_default` hay tương tự — không tồn tại trên .55
- KHÔNG bind container `0.0.0.0:80/443` — đụng host nginx
- KHÔNG tạo Linux user trùng tên với mwp site
- KHÔNG `DROP DATABASE wp_*` (đó là production WP sites)
- KHÔNG `systemctl restart nginx` khi chưa cần — reload đủ trừ khi đổi user/group
- KHÔNG run command destructive (rm -rf, DROP, force push) mà không hỏi user trước
- KHÔNG assume image cũ vẫn còn — `docker compose pull` trước update major
- KHÔNG để credentials ra ngoài file mode 600
