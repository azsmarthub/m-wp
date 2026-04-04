# mwp — AI Agent Guidelines

> **Mục đích file này:** Cung cấp đầy đủ context để AI assistant bắt đầu làm việc ngay,
> không cần hỏi lại từ đầu.
>
> **Project:** `~/projects/m-wp`
> **CLI command:** `mwp`
> **Version:** 0.1.0 (Phase 1 complete)
> **Last updated:** 2026-04-04

---

## 1. DỰ ÁN LÀ GÌ

**mwp** (Multi-site WordPress) là CLI tool quản lý **nhiều WordPress sites trên 1 VPS**,
viết bằng Bash thuần. Không có web UI, không có daemon — chỉ là shell scripts.

### Vị trí trong ecosystem của Dương

| Project | Path | Mô tả | Quan hệ |
|---------|------|-------|---------|
| **az-wp** | `~/projects/az-wp` | Single-site WordPress (CLI: `azwp`) | Nguồn học hỏi, KHÔNG gộp vào |
| **m-wp** | `~/projects/m-wp` | Multi-site WordPress (CLI: `mwp`) | Dự án này |
| **az-panel** | `~/projects/az-panel` | Web UI panel (React+Hono) | Giai đoạn sau, KHÔNG liên quan hiện tại |

**Quy tắc:** Ba dự án hoàn toàn độc lập. Không copy code từ az-wp vào m-wp — chỉ học ý tưởng.

---

## 2. TRIẾT LÝ THIẾT KẾ

```
az-wp  (single):  1 VPS = 1 WordPress site, cài xong là chạy
m-wp   (multi):   1 VPS = N WordPress sites, tách biệt hoàn toàn
```

**Hai phase rõ ràng:**

```
Phase A — Server Setup (chạy 1 lần):
  bash /opt/m-wp/multi/install.sh
  → Cài Nginx, PHP, MariaDB, Redis, WP-CLI, UFW, Fail2ban
  → Cấu hình server-level (nginx.conf cho multi-domain, disable PHP www pool)
  → Cài symlink: mwp → /usr/local/bin/mwp
  → KHÔNG tạo site nào

Phase B — Site Management (chạy nhiều lần):
  mwp site create example.com
  mwp site delete example.com
  mwp php switch example.com 8.2
  mwp backup full example.com
  ...
```

**Không bao giờ để Phase A làm việc của Phase B và ngược lại.**

---

## 3. CẤU TRÚC THƯ MỤC

```
m-wp/
├── multi/
│   ├── install.sh        ← Phase A: server setup (chạy 1 lần, cần root)
│   └── menu.sh           ← Phase B: CLI 'mwp' (symlink tới /usr/local/bin/mwp)
├── lib/
│   ├── common.sh         ← Core: logging, registry helpers, template renderer, apt
│   ├── registry.sh       ← Site registry: add/remove/list/info
│   ├── multi-site.sh     ← site_create(), site_delete(), site_enable/disable()
│   ├── multi-nginx.sh    ← nginx_create/delete/enable/disable_site(), cache_purge_site()
│   ├── multi-php.sh      ← php_install_version(), php_switch_site(), php_create/delete_pool()
│   ├── multi-ssl.sh      ← ssl_issue()
│   └── multi-backup.sh   ← backup_site(), restore_site()
├── templates/
│   ├── nginx/
│   │   └── multi-site.conf.tpl   ← Nginx vhost per site (FastCGI cache + PHP socket)
│   └── php/
│       └── multi-pool.conf.tpl   ← PHP-FPM pool per site (isolated)
└── VERSION               ← 0.1.0
```

---

## 4. STATE & REGISTRY (quan trọng)

### Server state: `/etc/mwp/server.conf`
Lưu thông tin server-level sau khi install.sh chạy:
```
DEFAULT_PHP=8.3
DB_ROOT_PASS=<generated>
REDIS_SOCK=/run/redis/redis-server.sock
MWP_DIR=/opt/m-wp
INSTALLED_AT=2026-04-04 10:00:00
SERVER_IP=1.2.3.4
```

### Site registry: `/etc/mwp/sites/<slug>.conf`
Mỗi site có 1 file riêng (slug = domain_to_slug(domain)):
```
DOMAIN=example.com
SLUG=example_com
SITE_USER=example_com
PHP_VERSION=8.3
WEB_ROOT=/home/example_com/example.com
DB_NAME=wp_example_com
DB_USER=wp_example_com
DB_PASS=<generated>
REDIS_DB=0          ← auto-allocated (0-15), mỗi site 1 DB index riêng
CACHE_PATH=/home/example_com/cache/fastcgi
STATUS=active
CREATED_AT=2026-04-04 10:00:00
```

### Quy tắc Redis DB allocation
- Mỗi site được cấp 1 Redis DB index (0–15)
- Auto-allocated bởi `redis_alloc_db()` trong `lib/common.sh`
- Nếu vượt 16 sites → báo lỗi (giới hạn shared Redis)

---

## 5. ISOLATION MODEL

Mỗi site chạy hoàn toàn tách biệt:

| Layer | Cơ chế |
|-------|--------|
| **Linux user** | Mỗi site = 1 user riêng, shell `/usr/sbin/nologin` |
| **Filesystem** | `/home/<user>/` permissions 750, site A không đọc được site B |
| **PHP-FPM** | Pool riêng mỗi site, `open_basedir` chỉ cho phép `/home/<user>` |
| **MariaDB** | DB + user riêng, chỉ có quyền trên DB của mình |
| **Redis** | DB index riêng (0–15) |
| **Nginx** | Vhost riêng, FastCGI cache riêng (`<user>_cache` zone) |

**`mwp site shell <domain>`** — dùng `su -s /bin/bash - <user>` (override nologin) để admin vào shell của site user.

---

## 6. TEMPLATE RENDERER

`render_template()` trong `lib/common.sh`: thay `{{VAR}}` bằng giá trị biến môi trường.

```bash
# Ví dụ sử dụng:
export DOMAIN="example.com"
export SITE_USER="example_com"
export PHP_VERSION="8.3"
GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S')" \
render_template "$MWP_DIR/templates/nginx/multi-site.conf.tpl" > /etc/nginx/sites-available/example.com.conf
```

Tất cả biến cần có trong env trước khi gọi `render_template`.

---

## 7. FLOW CHI TIẾT: `mwp site create <domain>`

```
1. Validate domain (format + chưa tồn tại trong registry)
2. Guard: kiểm tra /etc/mwp/server.conf + nginx sites-enabled (install.sh đã chạy chưa)
3. Derive variables:
   - SITE_USER = domain_to_slug(domain)  [e.g. example_com]
   - WEB_ROOT  = /home/<user>/<domain>
   - CACHE_PATH = /home/<user>/cache/fastcgi
   - DB_NAME/USER/PASS = generated
   - REDIS_DB = redis_alloc_db() → 0-15
   - PHP_VERSION = server_get("DEFAULT_PHP") hoặc 8.3
4. _site_create_user   → useradd + mkdir dirs + chown
5. _site_create_db     → CREATE DATABASE + CREATE USER (dùng DB_ROOT_PASS từ server.conf)
6. php_create_pool     → render multi-pool.conf.tpl → /etc/php/<ver>/fpm/pool.d/<user>.conf
7. nginx_create_site   → render multi-site.conf.tpl → /etc/nginx/sites-available/<domain>.conf + symlink
8. _site_install_wordpress → wp core download + wp config create + wp core install + redis enable
9. _site_issue_ssl_or_skip → DNS check (dig/getent) → certbot nếu DNS đã trỏ, skip nếu chưa
10. registry_add        → /etc/mwp/sites/<slug>.conf
```

---

## 8. CODING RULES

### Shell scripts
- **Mọi file:** `#!/usr/bin/env bash` + `set -euo pipefail`
- **Guard double-source:** `[[ -n "${_MWP_XXX_LOADED:-}" ]] && return 0`
- **Logging:** dùng `log_info`, `log_success`, `log_warn`, `log_error`, `log_sub` từ `common.sh`
- **Die on error:** `die "message"` (log_error + exit 1)
- **Input validation:** validate ở đầu function, fail fast
- **Cleanup:** `trap 'rm -rf "$tmp_dir"' EXIT` khi dùng tmp files

### Naming
```
lib/          → kebab-case.sh
templates/    → kebab-case.conf.tpl
functions     → snake_case()
variables     → UPPER_CASE (exported) hoặc lower_case (local)
```

### Idempotency
- `install.sh` phải idempotent (safe to re-run)
- `site_create()` phải check site đã tồn tại trước khi tạo
- MariaDB secure: không regenerate root pass nếu đã có

### Dependency loading
- `menu.sh` lazy-loads libs qua `_load_site_libs()` — chỉ source khi cần
- Lib files dùng guard `_MWP_XXX_LOADED` tránh double-source

---

## 9. CLI REFERENCE (`mwp help`)

```
mwp sites                        List all sites
mwp site create <domain>         Create new WordPress site
mwp site delete <domain>         Delete site
mwp site info   <domain>         Show site details
mwp site enable/disable <domain> Enable/disable site
mwp site shell  <domain>         Enter site user shell (bash)

mwp php list                     List installed PHP versions
mwp php install <version>        Install PHP 8.1/8.2/8.3/8.4
mwp php switch  <domain> <ver>   Switch site PHP version

mwp cache purge  <domain>        Purge FastCGI + Redis cache
mwp cache purge-all              Purge all sites

mwp ssl issue  <domain>          Issue Let's Encrypt SSL
mwp ssl renew                    Renew all certificates
mwp ssl status <domain>          Check SSL expiry

mwp backup full  <domain>        Full backup (files + DB)
mwp backup db    <domain>        Database only
mwp backup all                   Backup all sites
mwp restore <domain> <file>      Restore from backup

mwp status                       Server overview
mwp status <domain>              Single site status
```

---

## 10. WHAT'S DONE / WHAT'S NEXT

### ✅ Phase 1 — Foundation (COMPLETE)

- [x] `lib/common.sh` — core helpers, registry, template renderer
- [x] `lib/registry.sh` — site registry CRUD
- [x] `multi/install.sh` — server setup (Nginx+PHP+MariaDB+Redis+WP-CLI+UFW)
- [x] `multi/menu.sh` — `mwp` CLI router
- [x] `lib/multi-site.sh` — `site_create/delete/enable/disable`
- [x] `lib/multi-nginx.sh` — per-site vhost, FastCGI cache, `cache_purge_site`
- [x] `lib/multi-php.sh` — multi-version PHP, isolated FPM pool, `php_switch_site`
- [x] `lib/multi-ssl.sh` — Certbot SSL issue + HTTPS vhost
- [x] `lib/multi-backup.sh` — backup/restore per site, auto-rotate
- [x] `templates/nginx/multi-site.conf.tpl`
- [x] `templates/php/multi-pool.conf.tpl`
- [x] Architecture review: clean Phase A (install) / Phase B (site management) separation

### 🔲 Phase 2 — Isolation Hardening

- [ ] `lib/multi-isolation.sh`
  - Filesystem: `chmod 711 /home` (traverse không list)
  - PHP-FPM: validate `open_basedir` + `disable_functions` per pool
  - MariaDB: verify user chỉ có quyền trên DB của mình
  - `mwp site check-isolation <domain>` — report isolation status

### 🔲 Phase 3 — GeoIP & DNS

- [ ] `lib/multi-geoip.sh` — GeoIP2 (MaxMind) block/allow by country
- [ ] `lib/multi-dns.sh` — Cloudflare API: auto-point A record, manage records

### 🔲 Phase 4 — Resource Management

- [ ] `lib/multi-resource.sh` — cgroups v2 via systemd slice (CPU%, MemoryMax per site)
- [ ] Resource plans: small/medium/large/unlimited
- [ ] Auto-retune FPM pools khi thêm/xóa site

### 🔲 Phase 5 — Polish & Testing

- [ ] `setup-multi.sh` — one-liner installer: `curl -sSL .../setup-multi.sh | bash`
- [ ] Shellcheck CI
- [ ] Test trên VPS thật (Ubuntu 22.04 / 24.04)
- [ ] GitHub repo + README

### 🔲 Tương lai (chưa scope)

- Clone site (clone WordPress từ domain này sang domain khác)
- WooCommerce preset (bypass cache cho cart/checkout)
- phpMyAdmin per-site (optional)

---

## 11. KNOWN ISSUES / DECISIONS

| Issue | Quyết định |
|-------|-----------|
| Redis giới hạn 16 DB index | Acceptable cho phase 1 (giới hạn 16 sites/VPS shared Redis). Phase 4 có thể dùng dedicated Redis per site |
| `mwp site shell` override nologin | Dùng `su -s /bin/bash - <user>` — admin có root nên OK |
| SSL auto-detect DNS | Dùng `dig` (fallback `getent`), skip SSL nếu DNS chưa trỏ → user chạy `mwp ssl issue` sau |
| MariaDB root pass | Lưu plaintext trong `/etc/mwp/server.conf` (chmod 600). Chấp nhận vì chỉ root đọc được |
| PHP default `www` pool | Disabled trong install.sh — không chạy bất kỳ PHP nào dưới www-data |

---

## 12. ENVIRONMENT

- **OS target:** Ubuntu 22.04 / 24.04 LTS
- **Min spec test:** 1 CPU / 1GB RAM + 1GB swap (auto-created)
- **Recommended multi-site:** 1 CPU / 2GB RAM (3-5 sites)
- **Stack:** Nginx mainline + PHP-FPM 8.3 (default) + MariaDB 10.11 + Redis 7 + WP-CLI
- **Install path:** `/opt/m-wp` (hoặc bất kỳ đâu, MWP_DIR tự detect qua symlink)
