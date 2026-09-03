# Installing wpdeploy on a VPS

Step-by-step walkthrough for going from a brand-new Ubuntu 24.04 VPS to a
live WordPress site. `README.md` has the quick-reference version; this
doc explains each command and what it actually does, so you're not just
copy-pasting blind.

## Before you start

- A fresh Ubuntu 24.04 LTS VPS, with root or sudo SSH access.
- The domain(s) you're going to host: create an **A record** (and AAAA if
  you have IPv6) pointing at the VPS's IP address, for each domain, before
  you run `create-site.sh`. DNS has to have already propagated — Let's
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

## 2. Get the scripts onto the server

Clone the repo directly on the VPS:

```bash
apt-get update -qq && apt-get install -y git
git clone git@github.com:todcan-dev/tod-wpdeploy.git /opt/wpdeploy
cd /opt/wpdeploy
chmod +x setup-server.sh create-site.sh list-sites.sh
```

(If the VPS doesn't have your SSH key for GitHub, use the HTTPS clone URL
instead: `https://github.com/todcan-dev/tod-wpdeploy.git`.)

## 3. Run the one-time server bootstrap

```bash
./setup-server.sh --php-version 8.3 --acme-email you@example.com
```

What this does, in order:

1. Installs nginx, PHP 8.3-FPM plus the extensions WordPress needs
   (mysqli, curl, gd, mbstring, xml, zip, imagick, redis).
2. Installs and secures MariaDB — sets a root password, removes anonymous
   users and the `test` database, and binds it to `127.0.0.1` so it's
   never reachable from outside the server.
3. Installs Redis, also bound to `127.0.0.1`.
4. Installs WP-CLI (`/usr/local/bin/wp`) and acme.sh (Let's Encrypt
   client), with acme.sh's renewal cron job registered automatically.
5. Configures `ufw` to allow only SSH (22), HTTP (80), and HTTPS (443),
   and enables it.
6. Configures `fail2ban` to watch SSH and nginx auth logs for brute-force
   attempts.
7. Creates `/etc/wpdeploy/sites.list`, the registry every site gets
   appended to.

It'll prompt you for a MariaDB root password if you don't pass
`--mysql-root-password 'something'` — just press Enter to have it
generate a strong one for you. That password is written once to
`/etc/wpdeploy/.mysql_root`, readable by root only; `create-site.sh` reads
it from there automatically, you don't need to remember it.

At the end it prints a summary of everything installed. **This step is
safe to re-run** — if it fails partway (a flaky apt mirror, a network
blip), just run the same command again; it detects what's already done
and skips it.

## 4. Create your first site

Make sure DNS for the domain is already pointing at this server (see
"Before you start"), then:

```bash
./create-site.sh example.com \
    --title "My Example Site" \
    --admin-user editor \
    --admin-email you@example.com
```

Flags (all optional except the domain):

| Flag | Default | Notes |
|---|---|---|
| `--title` | the domain name | Site title shown in WordPress |
| `--admin-user` | `admin` | WordPress admin username |
| `--admin-email` | `admin@<domain>` | WordPress admin email |
| `--admin-password` | auto-generated | If omitted, a random 16-char password is generated and printed once at the end — **copy it down immediately**, it's not saved anywhere |

Want to see exactly what it *would* do first, without touching anything?

```bash
./create-site.sh example.com --dry-run
```

That prints the computed Linux username, database name, socket path,
next free Redis index, and so on, then exits.

### What happens when you run it for real

1. Validates the domain and checks it's not already registered.
2. Creates a dedicated, login-disabled Linux user for the site.
3. Creates `/var/www/example.com/htdocs`, owned by that user.
4. Creates a PHP-FPM pool for the site with its own socket, confined to
   that directory (`open_basedir`) with shell-exec functions disabled.
5. Creates a MariaDB database and a database user whose grants are
   scoped to that one database only.
6. Picks the next free Redis DB index (0–15).
7. Writes an nginx vhost and reloads nginx.
8. Requests a Let's Encrypt certificate via acme.sh (this is the step
   that needs working DNS) and rewrites the vhost to serve HTTPS with an
   HTTP→HTTPS redirect.
9. Downloads and installs WordPress via WP-CLI, wires up the DB and
   Redis object cache constants in `wp-config.php`, and installs +
   activates the Redis object cache plugin.
10. Appends the site to `/etc/wpdeploy/sites.list`.

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
  Redis DB index:  0
  PHP-FPM pool:    /etc/php/8.3/fpm/pool.d/example_com.conf
```

Visit `https://example.com/wp-admin/` and log in with those credentials.

## 5. Add more sites

Same command, different domain — just repeat step 4 for each one:

```bash
./create-site.sh second-site.com --admin-email you@example.com
./create-site.sh third-site.com --admin-email you@example.com
```

Each one gets fully isolated resources; a compromise on one site can't
reach another site's files, database, or PHP process.

You can host up to 16 sites per server before you run into the shared
Redis instance's default DB-index limit (0–15) — `create-site.sh` will
refuse the 17th with a clear error telling you to either raise
`databases` in `/etc/redis/redis.conf` or run a second Redis instance.

## 6. Check what's installed

```bash
./list-sites.sh
./list-sites.sh --verbose   # + disk usage per site and cert expiry date
```

## Troubleshooting

- **"Let's Encrypt validation failed for '...'"** — DNS for the domain
  isn't pointing at this server yet, or port 80 isn't reachable from the
  internet (check `ufw status`, check no other firewall is in front of
  the VPS). Fix that, then re-run `create-site.sh` with the same domain —
  the earlier partial state was already rolled back, so it's a clean
  retry.
- **"'<domain>' is already provisioned"** — it's in
  `/etc/wpdeploy/sites.list` already. Check `./list-sites.sh`. To
  re-provision from scratch you'd need to remove that line and manually
  clean up the Linux user, database, pool file, and vhost — there's no
  `delete-site.sh` (out of scope for this tool by design).
- **Lost/forgot a generated admin password** — it was only ever printed
  once. Reset it with:
  `sudo -u <linux_user> wp --path=/var/www/<domain>/htdocs user update <admin_user> --user_pass='newpassword'`
- **Need the MariaDB root password** — `sudo cat /etc/wpdeploy/.mysql_root`
  (root only).

## Updating wpdeploy itself

```bash
cd /opt/wpdeploy
git pull
```

Pulling changes doesn't touch already-provisioned sites — `setup-server.sh`
and `create-site.sh` only act on what you explicitly run them against.
