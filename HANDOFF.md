# mwp — Handoff Prompt

> Copy toàn bộ nội dung file này làm tin nhắn đầu tiên trong conversation mới.

---

Tôi đang phát triển **mwp** — CLI tool quản lý multi-site WordPress trên 1 VPS, viết bằng Bash thuần.
Project nằm tại `~/projects/m-wp`. Hãy đọc `CLAUDE.md` trong project để nắm đầy đủ context trước khi làm việc.

---

## Trạng thái hiện tại (2026-04-04)

### ✅ Đã hoàn thành

**Phase 1–3 — Foundation + Isolation + Deploy Ready**
- Core libs: `common.sh`, `registry.sh`
- Site CRUD: `lib/multi-site.sh` — `site_create()`, `site_delete()`, `site_enable/disable()`
- Nginx: `lib/multi-nginx.sh` — vhost per site, FastCGI cache zone riêng
- PHP: `lib/multi-php.sh` — multi-version, isolated pool per site, `open_basedir`
- SSL: `lib/multi-ssl.sh` — certbot + auto-detect DNS
- Backup/Restore: `lib/multi-backup.sh` — full/db, auto-rotate
- Isolation: `lib/multi-isolation.sh` — 9-point audit per site
- Tuning: `lib/multi-tuning.sh` — auto-retune FPM pools sau create/delete
- Templates: `templates/nginx/multi-site.conf.tpl`, `templates/php/multi-pool.conf.tpl`
- One-liner installer: `setup-multi.sh`
- CLI router: `multi/menu.sh`
- Server setup: `multi/install.sh`

**Bug fixes (session hôm nay)**
- Bug 1: RAM preflight không còn `die` — chỉ warn
- Bug 2: `registry_add` (step 8) trước `tuning_retune_all` (step 9) trong `site_create()`
- Bug 3: `step_fail2ban` gộp vào `step_firewall()`, không còn orphaned call
- Bug 4: MariaDB 11.4 LTS từ official repo (`mariadb_repo_setup`)
- Bug 5: WP admin user đổi từ `"admin"` → `"wpadm<6-char-random>"`
- Bug 6: Xoá `detect_ram_mb >/dev/null` vô nghĩa trong `main()`
- Bug 7: `step_panel_url` (user input) chuyển lên TRƯỚC `confirm "Start server setup?"`

**OS target: Ubuntu 24.04 LTS only. MariaDB 11.4 LTS.**

**Interactive TUI menu (session hôm nay)**

File mới: `lib/multi-menu.sh` — 3-level TUI:

```
Level 0  mwp                  → Root menu (server overview + 6 categories)
Level 1  mwp site             → Sites list (filter, numbered picker, tạo mới)
         mwp site <keyword>   → Sites list filtered (e.g. "mwp site shop")
Level 2  chọn site số         → Site detail (9 actions: info/enable/disable/php/cache/backup/restore/isolation/shell/ssl)
```

Direct commands vẫn hoạt động bypass menu hoàn toàn:
```bash
mwp site create example.com
mwp backup full example.com
mwp php switch example.com 8.2
```

---

### 🔲 Việc cần làm tiếp theo

**Phase 4 — Test trên VPS thật (NEXT)**
- Ubuntu 24.04, 1 CPU / 1GB RAM, fresh install
- Flow test: `install.sh` → `mwp site create` × 2 → `mwp php switch` → `mwp retune` → backup/restore
- Verify: `mwp site check-isolation` → tất cả green
- Fix bugs phát sinh, push GitHub

**Phase 5 — PowerDNS Nameserver**
- `lib/multi-dns.sh` — cài PowerDNS + MySQL backend
- VPS tự làm ns1/ns2 cho các domain
- `mwp dns zone-add/del <domain>`
- `mwp dns record-add/del/list <domain> <type> <value>`
- Auto-add DNS zone khi `mwp site create`

**Phase 6 — GeoIP (MaxMind GeoLite2)**
- `lib/multi-geoip.sh`
- `mwp geoip block <domain> <country_code>`
- `mwp geoip allow-only <domain> <country_codes>`
- User có MaxMind account

**Phase 7 — Resource Limits (optional, cgroups v2)**
- `mwp resource set <domain> --cpu 50% --mem 512M`

---

## Cấu trúc file quan trọng

```
m-wp/
├── setup-multi.sh              ← curl | bash installer
├── multi/
│   ├── install.sh              ← Phase A: server setup (chạy 1 lần)
│   └── menu.sh                 ← CLI entry point (symlink /usr/local/bin/mwp)
├── lib/
│   ├── common.sh               ← logging, helpers, render_template, apt
│   ├── registry.sh             ← /etc/mwp/sites/*.conf CRUD
│   ├── multi-site.sh           ← site_create/delete/enable/disable
│   ├── multi-nginx.sh          ← nginx vhost management
│   ├── multi-php.sh            ← php version + pool management
│   ├── multi-ssl.sh            ← certbot SSL
│   ├── multi-backup.sh         ← backup/restore
│   ├── multi-isolation.sh      ← isolation hardening + audit
│   ├── multi-tuning.sh         ← FPM auto-tune
│   └── multi-menu.sh           ← Interactive TUI (3-level)
├── templates/
│   ├── nginx/multi-site.conf.tpl
│   ├── nginx/panel-placeholder.conf.tpl
│   └── php/multi-pool.conf.tpl
├── CLAUDE.md                   ← Full project context cho AI
└── HANDOFF.md                  ← File này
```

## State files trên VPS

```
/etc/mwp/server.conf            ← DB_ROOT_PASS, DEFAULT_PHP, REDIS_SOCK, SERVER_IP
/etc/mwp/sites/<slug>.conf      ← Per-site registry
```

## Coding rules (tóm tắt)

- `#!/usr/bin/env bash` + `set -euo pipefail` mọi file
- Guard double-source: `[[ -n "${_MWP_XXX_LOADED:-}" ]] && return 0`
- Log: `log_info`, `log_success`, `log_warn`, `log_error`, `log_sub`, `die`
- Không copy code từ `az-wp` vào `m-wp` — chỉ học ý tưởng
- Ba dự án hoàn toàn độc lập: `az-wp` / `m-wp` / `az-panel`
