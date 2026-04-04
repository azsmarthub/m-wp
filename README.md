# mwp — Multi-site WordPress CLI

> Manage multiple WordPress sites on a single VPS via command line.
> One server. Many sites. Full isolation.

## Quick Install

```bash
curl -sSL https://raw.githubusercontent.com/azsmarthub/m-wp/main/setup-multi.sh | sudo bash
```

Or manually:

```bash
git clone https://github.com/azsmarthub/m-wp.git /opt/m-wp
sudo bash /opt/m-wp/multi/install.sh
```

## Requirements

- Ubuntu 22.04 or 24.04 LTS (fresh install)
- 1 CPU / 1GB RAM minimum (2GB+ recommended for 3+ sites)
- Root access

## What gets installed

| Component | Version |
|-----------|---------|
| Nginx | Mainline (official repo) |
| PHP-FPM | 8.3 (default, multi-version supported) |
| MariaDB | 10.11+ |
| Redis | 7 |
| WP-CLI | Latest |
| Certbot | Latest |
| UFW + Fail2ban | Latest |

## Usage

```bash
# List all sites
mwp sites

# Create a new WordPress site
mwp site create example.com

# Site management
mwp site delete  example.com
mwp site enable  example.com
mwp site disable example.com
mwp site info    example.com
mwp site shell   example.com        # Enter site user shell
mwp site check-isolation example.com  # Audit isolation

# PHP
mwp php list
mwp php install 8.2
mwp php switch example.com 8.2

# Cache
mwp cache purge example.com
mwp cache purge-all

# SSL
mwp ssl issue example.com
mwp ssl renew
mwp ssl status example.com

# Backup
mwp backup full example.com
mwp backup db   example.com
mwp backup all
mwp restore example.com /home/example_com/backups/example.com-full-20260401.tar.gz

# Server
mwp status
mwp status example.com
mwp retune              # Recalculate FPM pools after adding/removing sites
mwp retune --dry-run    # Preview retune without applying

# Panel URL
mwp panel info
mwp panel setup         # Set hostname for future web UI (sv1.yourdomain.com)
mwp panel ssl
```

## Isolation model

Each site runs fully isolated:

- **Linux user** — dedicated user per site, shell `/usr/sbin/nologin`
- **Filesystem** — `/home` is `711`, each site home is `750`
- **PHP-FPM** — dedicated pool with `open_basedir` restricted to site home
- **MariaDB** — dedicated database + user, no cross-site access
- **Redis** — dedicated DB index (0–15) per site
- **Nginx** — dedicated vhost + FastCGI cache zone per site

Verify isolation: `mwp site check-isolation example.com`

## Directory structure on VPS

```
/opt/m-wp/              ← mwp installation
/etc/mwp/
├── server.conf         ← Server-level config (PHP version, DB root, Redis socket)
└── sites/
    └── example_com.conf ← Per-site registry

/home/<site_user>/
├── <domain>/           ← WordPress files
├── cache/fastcgi/      ← FastCGI cache
├── logs/               ← access.log, error.log, php-error.log
├── backups/            ← Site backups
└── tmp/                ← PHP upload/session temp
```

## Auto-tuning

PHP-FPM pools are automatically sized based on available RAM and site count.
When you add or remove a site, `mwp retune` runs automatically.

Manual retune: `mwp retune`

## License

MIT
