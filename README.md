# wpdeploy

Minimal, secure-by-default WordPress provisioning for a single Ubuntu 24.04
VPS. No dashboard, no multisite, no per-site PHP version, no monitoring
stack — just three scripts that give every site its own Linux user,
PHP-FPM pool, database, and Redis DB index, with a Let's Encrypt
certificate that's never optional.

> Full step-by-step walkthrough (VPS setup through your first WordPress
> site, with explanations and troubleshooting): [INSTALL.md](INSTALL.md).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/todcan-dev/tod-wpdeploy/main/install.sh -o install.sh
sudo bash install.sh
```

This clones wpdeploy to `/opt/wpdeploy` and puts `tod` on your PATH.
Re-running it later just `git pull`s to update. (Prefer to do it by hand,
or the repo's private? `git clone` it yourself instead — see
[INSTALL.md](INSTALL.md).)

## Usage

Like WordOps' `wo`, wpdeploy gives you a single `tod` command once it's
set up — no need to remember individual script paths.

### 1. Bootstrap the server (once)

```bash
sudo ./setup-server.sh --php-version 8.3 --acme-email you@example.com \
    --admin-user yourname --admin-email you@example.com
```

Installs and configures nginx, PHP-FPM, MariaDB, Redis, WP-CLI, acme.sh,
ufw, and fail2ban — and, as its last step, symlinks `tod` into
`/usr/local/bin/tod` so it's available everywhere from here on. Idempotent
— re-run any time to pick up interrupted steps; it won't break an existing
setup. Never prompts for anything — the MariaDB root password (and every
per-site DB/admin password later) is auto-generated unless you pass
`--mysql-root-password` yourself; it's stored once at
`/etc/wpdeploy/.mysql_root`, readable by root only.

`--admin-user`/`--admin-email` here are the WordPress admin identity
**every site will use by default** — the same idea as WordOps' global
config. Set them once and every `tod site create` afterward just uses
them; you only pass `--admin-user`/`--admin-email` again if a specific
site needs a different admin.

### 2. Create a site (per site)

Point the domain's DNS at this server first, then:

```bash
sudo tod site create example.com --title "Example Site"
```

That's it — admin user/email come from the server-wide default set in
step 1. Override per-site if you need to:
`tod site create example.com --admin-user someone-else --admin-email someone-else@example.com`.

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
tod site list              # domain, linux user, db, redis index, php, created
tod site list --verbose    # + disk usage and cert expiry
```

`tod` is just a thin dispatcher — `tod setup`, `tod site create`, and
`tod site list` call `setup-server.sh`, `create-site.sh`, and
`list-sites.sh` directly, so the raw scripts still work exactly the same
if you prefer them (`./create-site.sh example.com --dry-run`, etc.).

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

- `install.sh` — one-command installer (clones the repo, puts `tod` on PATH).
- `tod` — command dispatcher (`tod setup` / `tod site create` / `tod site list`).
- `setup-server.sh` — one-time server bootstrap.
- `create-site.sh` — provisions one isolated site.
- `list-sites.sh` — reads `/etc/wpdeploy/sites.list`.
- `templates/php-fpm-pool.conf.template` — PHP-FPM pool, filled in per site.
- `templates/nginx-vhost-http.conf.template` — vhost used before a cert exists.
- `templates/nginx-vhost-ssl.conf.template` — vhost swapped in after issuance.
- `/etc/wpdeploy/sites.list` — the registry:
  `domain|linux_user|db_name|redis_index|php_version|created_date`
- `/etc/wpdeploy/config` — server-wide defaults (`DEFAULT_ADMIN_USER`,
  `DEFAULT_ADMIN_EMAIL`), set via `tod setup --admin-user/--admin-email`.

## Not included, on purpose

Multisite, a web dashboard, per-site PHP version switching, and a
monitoring stack. If you need those, this isn't the tool — that's the
point.
