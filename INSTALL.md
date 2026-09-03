# Installing wpdeploy on a VPS

Step-by-step walkthrough for going from a brand-new Ubuntu 24.04 VPS to a
live WordPress site. `README.md` has the quick-reference version; this
doc explains each command and what it actually does, so you're not just
copy-pasting blind.

Once it's bootstrapped, wpdeploy gives you one command — `tod` — the same
way WordOps gives you `wo`. Everything below after step 3 is just `tod`.

## Before you start

- A fresh Ubuntu 24.04 LTS VPS, with root or sudo SSH access.
- The domain(s) you're going to host: create an **A record** (and AAAA if
  you have IPv6) pointing at the VPS's IP address, for each domain, before
  you run `tod site create`. DNS has to have already propagated — Let's
  Encrypt validates by connecting to your domain over HTTP, so if DNS
  isn't live yet, certificate issuance will fail (the error message tells
  you this explicitly if it happens).
- Nothing else already running on ports 80/443 (a fresh VPS is fine; a
  server that already runs another web stack is not what this is for).

## 1. Get onto the server

```bash
ssh root@YOUR_SERVER_IP
```

If you're not root, use a user with sudo and prefix commands below with
`sudo`.

## 2. Install wpdeploy

The one-line installer downloads the repo to `/opt/wpdeploy` and puts
`tod` on your PATH:

```bash
curl -fsSL https://raw.githubusercontent.com/todcan-dev/tod-wpdeploy/main/install.sh -o install.sh
sudo bash install.sh
```

(Downloads to a file first, then runs it — same reasoning as WordOps'
`wget wo && sudo bash wo`: a truncated download fails loudly instead of
silently executing.)

If the repo is private, or you'd rather do it by hand:

```bash
apt-get update -qq && apt-get install -y git
git clone git@github.com:todcan-dev/tod-wpdeploy.git /opt/wpdeploy   # or the https:// URL
cd /opt/wpdeploy
chmod +x setup-server.sh create-site.sh delete-site.sh list-sites.sh tod
ln -sf "$(pwd)/tod" /usr/local/bin/tod
```

## 3. Run the one-time server bootstrap

```bash
sudo tod setup --php-version 8.3 --acme-email you@example.com \
    --admin-user yourname --admin-email you@example.com
```

`--admin-user`/`--admin-email` here matter more than they look: they set
the **server-wide default WordPress admin identity**. If you're the one
provisioning every site (the common case), set them once here and never
type them again — every `tod site create` afterward uses this admin
automatically, the same way WordOps' global config works. You can still
override per-site with `--admin-user`/`--admin-email` on `tod site
create` itself, for the rare site that needs a different admin.

What this does, in order:

1. Installs nginx, PHP 8.3-FPM plus the extensions WordPress needs
   (mysqli, curl, gd, mbstring, xml, zip, imagick, redis).
2. Installs and secures MariaDB — sets a root password, removes anonymous
   users and the `test` database, and binds it to `127.0.0.1` so it's
   never reachable from outside the server.
3. Installs Redis (bound to `127.0.0.1`) and disables its default shared
   instance — each site gets its own dedicated Redis instance instead,
   created by `tod site create`.
4. Installs WP-CLI (`/usr/local/bin/wp`) and acme.sh (Let's Encrypt
   client), with acme.sh's renewal cron job registered automatically.
5. Configures `ufw` to allow only SSH (22), HTTP (80), and HTTPS (443),
   and enables it.
6. Configures `fail2ban` to watch SSH and nginx auth logs for brute-force
   attempts.
7. Creates `/etc/wpdeploy/sites.list`, the registry every site gets
   appended to.
8. Re-links `tod` into `/usr/local/bin/tod` (already done if you used
   `install.sh`; this makes the manual-clone path work the same way).
9. If `--admin-user`/`--admin-email` were given, writes them to
   `/etc/wpdeploy/config` as the default every `tod site create` reads.

Nothing here is interactive — like WordOps, every credential is
generated for you, never asked for. The MariaDB root password is
auto-generated unless you pass `--mysql-root-password 'something'`
yourself, and written once to `/etc/wpdeploy/.mysql_root` (readable by
root only). `tod site create` reads it from there automatically, and
generates its own random per-site database password and (unless you pass
`--admin-password`) WordPress admin password the same way — you never
have to type or invent a password anywhere in this process.

At the end it prints a summary of everything installed. **This step is
safe to re-run** — if it fails partway (a flaky apt mirror, a network
blip), just run the same command again; it detects what's already done
and skips it.

## 4. Create your first site

Make sure DNS for the domain is already pointing at this server (see
"Before you start"), then:

```bash
tod site create example.com --title "My Example Site"
```

(Still need `sudo` in front if you're not logged in as root:
`sudo tod site create example.com ...`.)

Notice there's no `--admin-user`/`--admin-email` here — they come from
the server-wide default you set in step 3. Only pass them again if this
particular site needs a different admin than your default:

```bash
tod site create example.com --title "My Example Site" \
    --admin-user someone-else --admin-email someone-else@example.com
```

Flags (all optional except the domain):

| Flag | Default | Notes |
|---|---|---|
| `--title` | the domain name | Site title shown in WordPress |
| `--admin-user` | server-wide default (`tod setup --admin-user`), or `admin` if none was set | WordPress admin username |
| `--admin-email` | server-wide default (`tod setup --admin-email`), or `admin@<domain>` if none was set | WordPress admin email |
| `--admin-password` | auto-generated | If omitted, a random 16-char password is generated and printed once at the end — **copy it down immediately**, it's not saved anywhere |

Want to see exactly what it *would* do first, without touching anything?

```bash
tod site create example.com --dry-run
```

That prints the computed Linux username, database name, socket path,
and so on, then exits.

### What happens when you run it for real

1. Validates the domain and checks it's not already registered.
2. Creates a dedicated, login-disabled Linux user for the site.
3. Creates `/var/www/example.com/` (site root, owned by that user) and
   `/var/www/example.com/htdocs` inside it (nginx's served directory).
4. Creates a PHP-FPM pool for the site with its own socket, confined to
   the site's whole directory (`open_basedir`, covering both the site
   root and `htdocs/`) with shell-exec functions disabled.
5. Creates a MariaDB database and a database user whose grants are
   scoped to that one database only.
6. Creates a dedicated Redis instance for the site (own unix socket,
   own random password — not a shared instance).
7. Writes an nginx vhost and reloads nginx.
8. Requests a Let's Encrypt certificate via acme.sh (this is the step
   that needs working DNS) and rewrites the vhost to serve HTTPS with an
   HTTP→HTTPS redirect.
9. Downloads and installs WordPress via WP-CLI, wires up the DB and Redis
   object cache constants in `wp-config.php` (written one directory above
   `htdocs/`, not inside it — WordPress and WP-CLI both look there
   automatically, so this needs no special `--path` handling), and
   installs + activates the Redis object cache plugin.
10. Appends the site to `/etc/wpdeploy/sites.list`.

`wp-config.php` deliberately lives in the site root, not inside
`htdocs/` — that's the directory nginx actually serves, so keeping the
DB/Redis credentials one level above it means a broken or overly
permissive nginx vhost can never expose the file over HTTP, even though
PHP-FPM (and a compromised plugin under it) can still reach it. This is
the same placement WordPress core and WP-CLI already support natively —
no site-specific configuration was needed to make it work.

If anything fails along the way, everything created for that site up to
that point is automatically rolled back (Linux user removed, database
dropped, pool/vhost files deleted) and the registry is left untouched —
you can just fix the problem (usually DNS) and re-run the same command.

When it finishes, you'll see something like:

```
==> Site provisioned: https://example.com

  Admin URL:       https://example.com/wp-admin/
  Admin user:      editor
  Admin password:  Xk9pQz2mN4wRtL8s  (generated — save this now, it is not stored anywhere)
  Database:        wp_example_com
  Linux user:      example_com
  Redis instance:  redis-server@example_com
  PHP-FPM pool:    /etc/php/8.3/fpm/pool.d/example_com.conf
```

Visit `https://example.com/wp-admin/` and log in with those credentials.

## 5. Add more sites

Same command, different domain — just repeat step 4 for each one:

```bash
tod site create second-site.com
tod site create third-site.com
```

Each one gets fully isolated resources; a compromise on one site can't
reach another site's files, database, or PHP process.

Each site gets its own Redis instance too, so there's no shared-instance
site-count cap to run into — the real ceiling is server RAM/CPU, since
every site now runs its own small `redis-server` process (same tradeoff
already accepted for PHP-FPM pools).

## 6. Check what's installed

```bash
tod site list
tod site list --verbose   # + Redis instance status, disk usage, cert expiry
```

## 7. Delete a site

```bash
tod site delete example.com
```

This is permanent: it removes the Linux user (and every file in
`/var/www/example.com`), drops the MariaDB database and user, deletes
the PHP-FPM pool and nginx vhost, revokes and removes the TLS
certificate, stops and removes the site's dedicated Redis instance, and
drops the registry entry. There's no backup step — back up anything you
need first.

It shows you exactly what's about to be deleted, then asks you to type
the domain name to confirm:

```
This will permanently delete:
  Linux user:       example_com (and /var/www/example.com, including all files)
  Database:         wp_example_com (and its user) -- all site data
  PHP-FPM pool:      /etc/php/8.3/fpm/pool.d/example_com.conf
  Nginx vhost:       /etc/nginx/sites-available/example.com
  TLS certificate:   /etc/nginx/ssl/example.com (and /root/.acme.sh/example.com)
  Redis instance:    redis-server@example_com (stopped and removed)
  Registry entry:    example.com in /etc/wpdeploy/sites.list

This cannot be undone. No backup is taken.
Type the domain to confirm deletion:
```

Want to see that plan without deleting anything? `tod site delete
example.com --dry-run`. Scripting this and don't want the prompt?
`tod site delete example.com --yes`.

## Command reference

```
tod setup [--php-version 8.3] [--acme-email you@example.com] [--mysql-root-password 'secret']
          [--admin-user name] [--admin-email you@example.com]
tod site create <domain> [--title "..."] [--admin-user name] [--admin-email you@example.com] [--admin-password 'secret'] [--dry-run]
tod site delete <domain> [--yes] [--dry-run]
tod site list [--verbose]
tod help
```

`tod` is a thin dispatcher — `tod setup`, `tod site create`,
`tod site delete`, and `tod site list` just call `setup-server.sh`,
`create-site.sh`, `delete-site.sh`, and `list-sites.sh` respectively. The
raw scripts (`./create-site.sh example.com --dry-run`, etc.) work exactly
the same if you ever want to call them directly.

## Troubleshooting

- **"Let's Encrypt validation failed for '...'"** — DNS for the domain
  isn't pointing at this server yet, or port 80 isn't reachable from the
  internet (check `ufw status`, check no other firewall is in front of
  the VPS). Fix that, then re-run `tod site create` with the same domain —
  the earlier partial state was already rolled back, so it's a clean
  retry.
- **"'<domain>' is already provisioned"** — it's in
  `/etc/wpdeploy/sites.list` already. Check `tod site list`. To
  re-provision from scratch, remove it first: `tod site delete
  example.com`.
- **Lost/forgot a generated admin password** — it was only ever printed
  once. Reset it with (`--path` still points at `htdocs/`; `wp` finds
  `wp-config.php` one directory up automatically):
  `sudo -u <linux_user> wp --path=/var/www/<domain>/htdocs user update <admin_user> --user_pass='newpassword'`
- **Need the MariaDB root password** — `sudo cat /etc/wpdeploy/.mysql_root`
  (root only).
- **Change the server-wide default admin later** — just re-run
  `tod setup --admin-user newname --admin-email newname@example.com`
  (or edit `/etc/wpdeploy/config` directly). It only affects sites
  created afterward, not ones already provisioned.
- **`tod: command not found`** — either `setup-server.sh` hasn't been run
  yet, or you're not in a shell that's picked up `/usr/local/bin` (it's
  in the default `$PATH` on Ubuntu, so this usually just means step 3
  hasn't completed). Fall back to `./tod ...` from inside `/opt/wpdeploy`
  in the meantime.

## Updating wpdeploy itself

Re-run the installer — it detects the existing `/opt/wpdeploy` checkout
and does a `git pull` instead of a fresh clone:

```bash
sudo bash install.sh
```

or by hand: `cd /opt/wpdeploy && git pull`. Either way, updating wpdeploy
doesn't touch already-provisioned sites — `tod setup` and
`tod site create` only act on what you explicitly run them against.
