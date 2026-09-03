# wpdeploy

Minimal, secure-by-default WordPress provisioning for a single Ubuntu 24.04
VPS. No dashboard, no multisite, no per-site PHP version, no monitoring
stack — just three scripts that give every site its own Linux user,
PHP-FPM pool, database, and dedicated Redis instance, with a Let's Encrypt
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
sudo ./setup-server.sh
```

Run it from a real terminal (i.e. over SSH, not piped) and it asks, like
WordOps does: your WordPress admin username and email (the default every
`tod site create` uses afterward — same idea as WordOps' global config),
whether to restrict SSH to the IP you're currently connecting from, and
whether to disable SSH password login (key-only from then on). Answer
once and you never have to retype any of it for future sites.

Prefer flags, or running it unattended? Everything above can be passed
directly and no prompt fires for whatever's already given:

```bash
sudo ./setup-server.sh --php-version 8.3 --acme-email you@example.com \
    --admin-user yourname --admin-email you@example.com \
    --ssh-allow-ip 203.0.113.5 --disable-password-auth yes
```

Installs and configures nginx, PHP-FPM, MariaDB, Redis, WP-CLI, acme.sh,
ufw, and fail2ban — and, as its last step, symlinks `tod` into
`/usr/local/bin/tod` so it's available everywhere from here on. Idempotent
— re-run any time to pick up interrupted steps; it won't break an existing
setup. The MariaDB root password (and every per-site DB/admin password
later) is always auto-generated, never prompted for; it's stored once at
`/etc/wpdeploy/.mysql_root`, readable by root only.

`--ssh-allow-ip` locks port 22 to one IP/CIDR instead of the whole
internet — pass `any` to explicitly leave it open. **If that address ever
changes you'll be locked out of SSH** until you fix it from your VPS
provider's web console; re-run `tod setup --ssh-allow-ip <new-ip>` (or
`any`) once you're back in.

`--disable-password-auth yes` turns off SSH password login entirely —
key-only from then on, which closes off brute-forcing/leaked-password
attacks far more effectively than the IP restriction alone. It **refuses**
to do this (and leaves password login enabled) if it can't find an
authorized SSH key for the account you connected as, so this can't lock
you out by itself the way the IP restriction can — but you still need a
working key before you say yes.

`--default-plugins "slug-a,slug-b"` (wordpress.org plugin slugs,
comma-separated) get installed and activated on every site `tod site
create` makes afterward, on top of the Redis object cache it always
installs. Not prompted for — ships with `updraftplus` baked in as the
built-in default (edit `DEFAULT_PLUGINS` at the top of `create-site.sh`
to change it); pass the flag only if you want something different.
Akismet and Hello Dolly are always removed from every new site
regardless; edit `REMOVE_DEFAULT_PLUGINS` at the top of `create-site.sh`
if you ever want to keep one.

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
(Linux user, DB name, socket path, Redis instance, etc.) without touching
the server.

This is the whole pipeline, in order: Linux user → site directory → PHP-FPM
pool → MariaDB database/user → dedicated Redis instance → nginx vhost (HTTP)
→ Let's Encrypt certificate → nginx vhost (HTTPS) → WordPress install →
Redis object cache plugin → registry entry. If any step fails, everything
created so far for that site is automatically rolled back and the registry
is left untouched — nothing failed is left half-provisioned.

### 3. List sites

```bash
tod site list              # domain, linux user, db, php, created
tod site list --verbose    # + Redis instance status, disk usage, cert expiry
```

### 4. Delete a site

```bash
tod site delete example.com
```

Permanently removes everything `create-site.sh` created for that domain —
Linux user, files, database, PHP-FPM pool, nginx vhost, TLS certificate,
its dedicated Redis instance — and drops the registry entry. Not
reversible; there's no backup step. Prompts you to type the domain to
confirm (skip with `--yes` for scripting); add `--dry-run` to see exactly
what would be removed first.

`tod` is just a thin dispatcher — `tod setup`, `tod site create`,
`tod site delete`, and `tod site list` call `setup-server.sh`,
`create-site.sh`, `delete-site.sh`, and `list-sites.sh` directly, so the
raw scripts still work exactly the same if you prefer them
(`./create-site.sh example.com --dry-run`, etc.).

## Isolation model

- **Linux**: each site is its own system user (`/usr/sbin/nologin`), owning
  `/var/www/<domain>` (site root) at `750`; `wp-config.php` lives directly
  in that site root, one level above the nginx-served `htdocs/`. nginx's
  `www-data` user is added to that site's group so it can read static files
  under `htdocs/`; only that site's own PHP-FPM pool (running as the site's
  user) can write to any of it.
- **PHP-FPM**: one pool per site, own unix socket
  (`/run/php/<user>.sock`), `open_basedir` scoped to the site's whole
  directory tree (site root + `htdocs/`, not just nginx's served root),
  and `exec,shell_exec,system,passthru,proc_open,popen` disabled.
- **nginx**: each vhost's `fastcgi_pass` points only at that site's socket.
- **wp-config.php placement**: kept one directory above nginx's `root`
  (`/var/www/<domain>/wp-config.php`, not `.../htdocs/wp-config.php`) —
  the same hardening WordPress core and WP-CLI both support natively, no
  extra config required. It doesn't hide the file from this site's own
  PHP-FPM worker or a compromised plugin (`open_basedir` covers the whole
  site root, and `www-data` still has OS-level group-read access either
  way) — what it buys is that a broken or overly permissive nginx vhost
  can never expose the raw file over HTTP, because nginx's serving root
  structurally doesn't reach that far up.
- **MariaDB**: bound to `127.0.0.1`, one database + one user per site,
  grants scoped to that database only, random password written only to
  that site's `wp-config.php`.
- **Redis**: own `redis-server@<site>` instance per site (systemd
  template, not a shared instance carved up by DB index), own unix
  socket, own random `requirepass` written only to that site's
  `wp-config.php` — same credential-based isolation model as MariaDB.
  No site-count cap from Redis anymore, since nothing is shared.
- **Firewall / brute-force**: ufw allows only 80/443 to everyone, plus 22
  — restricted to one IP/CIDR by default (`tod setup` asks for it, or set
  it with `--ssh-allow-ip`; pass `any` to leave SSH open to everyone).
  `tod setup` also offers to disable SSH password login entirely
  (`--disable-password-auth yes`), refusing unless it finds an authorized
  key already in place. fail2ban watches sshd and nginx on top of that.

## Files

- `install.sh` — one-command installer (clones the repo, puts `tod` on PATH).
- `tod` — command dispatcher (`tod setup` / `tod site create` / `tod site delete` / `tod site list`).
- `setup-server.sh` — one-time server bootstrap.
- `create-site.sh` — provisions one isolated site.
- `delete-site.sh` — permanently removes one site.
- `list-sites.sh` — reads `/etc/wpdeploy/sites.list`.
- `templates/php-fpm-pool.conf.template` — PHP-FPM pool, filled in per site.
- `templates/nginx-vhost-http.conf.template` — vhost used before a cert exists.
- `templates/nginx-vhost-ssl.conf.template` — vhost swapped in after issuance.
- `/etc/wpdeploy/sites.list` — the registry:
  `domain|linux_user|db_name|php_version|created_date`
- `/etc/wpdeploy/config` — server-wide defaults (`DEFAULT_ADMIN_USER`,
  `DEFAULT_ADMIN_EMAIL`), set via `tod setup --admin-user/--admin-email`.

## Not included, on purpose

Multisite, a web dashboard, per-site PHP version switching, and a
monitoring stack. If you need those, this isn't the tool — that's the
point.
