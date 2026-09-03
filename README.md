# wpdeploy

Minimal, secure-by-default WordPress provisioning for a single Ubuntu 24.04
VPS. No dashboard, no multisite, no per-site PHP version, no monitoring
stack — just three scripts that give every site its own Linux user,
PHP-FPM pool, database, and Redis DB index, with a Let's Encrypt
certificate that's never optional.

## Install

```bash
git clone <this repo> /opt/wpdeploy   # or download the files however you like
cd /opt/wpdeploy
chmod +x setup-server.sh create-site.sh list-sites.sh
```

## Usage

### 1. Bootstrap the server (once)

```bash
sudo ./setup-server.sh --php-version 8.3 --acme-email you@example.com
```

Installs and configures nginx, PHP-FPM, MariaDB, Redis, WP-CLI, acme.sh,
ufw, and fail2ban. Idempotent — re-run any time to pick up interrupted
steps; it won't break an existing setup. If you omit
`--mysql-root-password`, you'll be prompted for one (or it'll generate one)
the first time only; it's stored at `/etc/wpdeploy/.mysql_root`, readable
by root only.

### 2. Create a site (per site)

Point the domain's DNS at this server first, then:

```bash
sudo ./create-site.sh example.com \
    --title "Example Site" \
    --admin-user editor \
    --admin-email you@example.com
```

Omit `--admin-password` and one is generated and printed once at the end
(it isn't stored anywhere else). Add `--dry-run` to see the full plan
(Linux user, DB name, socket path, Redis index, etc.) without touching the
server.

This is the whole pipeline, in order: Linux user → site directory → PHP-FPM
pool → MariaDB database/user → Redis DB index → nginx vhost (HTTP) →
Let's Encrypt certificate → nginx vhost (HTTPS) → WordPress install →
Redis object cache plugin → registry entry. If any step fails, everything
created so far for that site is automatically rolled back and the registry
is left untouched — nothing failed is left half-provisioned.

### 3. List sites

```bash
./list-sites.sh              # domain, linux user, db, redis index, php, created
./list-sites.sh --verbose    # + disk usage and cert expiry
```

## Isolation model

- **Linux**: each site is its own system user (`/usr/sbin/nologin`), owning
  `/var/www/<domain>/htdocs` at `750`. nginx's `www-data` user is added to
  that site's group so it can read static files; only that site's own
  PHP-FPM pool (running as the site's user) can write to it.
- **PHP-FPM**: one pool per site, own unix socket
  (`/run/php/<user>.sock`), `open_basedir` scoped to the site directory,
  and `exec,shell_exec,system,passthru,proc_open,popen` disabled.
- **nginx**: each vhost's `fastcgi_pass` points only at that site's socket.
- **MariaDB**: bound to `127.0.0.1`, one database + one user per site,
  grants scoped to that database only, random password written only to
  that site's `wp-config.php`.
- **Redis**: one shared instance, one DB index (0–15) per site, tracked in
  the registry. `create-site.sh` refuses to provision a 17th site and
  tells you to bump `databases` in `redis.conf` or add a second instance.
- **Firewall / brute-force**: ufw allows only 22/80/443; fail2ban watches
  sshd and nginx.

## Files

- `setup-server.sh` — one-time server bootstrap.
- `create-site.sh` — provisions one isolated site.
- `list-sites.sh` — reads `/etc/wpdeploy/sites.list`.
- `templates/php-fpm-pool.conf.template` — PHP-FPM pool, filled in per site.
- `templates/nginx-vhost-http.conf.template` — vhost used before a cert exists.
- `templates/nginx-vhost-ssl.conf.template` — vhost swapped in after issuance.
- `/etc/wpdeploy/sites.list` — the registry:
  `domain|linux_user|db_name|redis_index|php_version|created_date`

## Not included, on purpose

Multisite, a web dashboard, per-site PHP version switching, and a
monitoring stack. If you need those, this isn't the tool — that's the
point.
