#!/usr/bin/env bash
set -euo pipefail

# wpdeploy :: create-site.sh <domain>
# Provisions one fully isolated WordPress site: dedicated Linux user,
# PHP-FPM pool + socket, MariaDB database/user, Redis DB index, nginx
# vhost, Let's Encrypt certificate, and a fresh WP install with the Redis
# object cache plugin enabled.

WPDEPLOY_DIR="/etc/wpdeploy"
SITES_LIST="$WPDEPLOY_DIR/sites.list"
MYSQL_ROOT_PW_FILE="$WPDEPLOY_DIR/.mysql_root"
ACME="/root/.acme.sh/acme.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates"

DRY_RUN=0
TITLE=""
ADMIN_USER="admin"
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
DOMAIN_ARG=""

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo ./create-site.sh <domain> [--title "My Site"] [--admin-user name]
                              [--admin-email you@example.com] [--admin-password 'secret']
                              [--dry-run]

Provisions an isolated WordPress site at <domain> with its own Linux user,
PHP-FPM pool, MariaDB database, Redis DB index, nginx vhost, and a
mandatory Let's Encrypt certificate. DNS for <domain> must already point
at this server.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --title) TITLE="$2"; shift 2 ;;
        --admin-user) ADMIN_USER="$2"; shift 2 ;;
        --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
        --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage ;;
        -*) die "Unknown flag: $1 (see --help)" ;;
        *) DOMAIN_ARG="$1"; shift ;;
    esac
done

[[ -n "$DOMAIN_ARG" ]] || usage
(( EUID == 0 )) || die "Must be run as root (sudo ./create-site.sh <domain>)"

for cmd in nginx mysql wp; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' not found — run setup-server.sh first"
done
[[ -x "$ACME" ]] || die "acme.sh not found at $ACME — run setup-server.sh first"
[[ -f "$MYSQL_ROOT_PW_FILE" ]] || die "MariaDB root password not found — run setup-server.sh first"
[[ -f "$SITES_LIST" ]] || die "$SITES_LIST not found — run setup-server.sh first"

PHP_VERSION="$(ls -1 /etc/php 2>/dev/null | sort -V | tail -n1)"
[[ -n "$PHP_VERSION" ]] || die "No PHP-FPM installation found — run setup-server.sh first"

# --- 1. Validate and normalize -----------------------------------------------

DOMAIN="${DOMAIN_ARG,,}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN#www.}"
DOMAIN="${DOMAIN%%/*}"

DOMAIN_REGEX='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$'
[[ "$DOMAIN" =~ $DOMAIN_REGEX ]] || die "'$DOMAIN_ARG' doesn't look like a valid domain"

if grep -q "^${DOMAIN}|" "$SITES_LIST" 2>/dev/null; then
    die "'$DOMAIN' is already provisioned (see $SITES_LIST)"
fi

NORMALIZED="${DOMAIN//./_}"
if (( ${#NORMALIZED} > 32 )); then
    HASH8="$(printf '%s' "$DOMAIN" | sha256sum | cut -c1-8)"
    NORMALIZED="${NORMALIZED:0:24}${HASH8}"
fi
# useradd's name rules dislike a leading digit; nudge it to a safe form.
[[ "$NORMALIZED" =~ ^[a-z_] ]] || NORMALIZED="s${NORMALIZED:0:31}"

LINUX_USER="$NORMALIZED"
DB_NAME="wp_${NORMALIZED}"      # 3 + <=32 chars, always well under MySQL's 64-char limit
DB_USER="$NORMALIZED"
SITE_BASE="/var/www/$DOMAIN"
SITE_DIR="$SITE_BASE/htdocs"
SOCKET="/run/php/${NORMALIZED}.sock"
POOL_FILE="/etc/php/${PHP_VERSION}/fpm/pool.d/${NORMALIZED}.conf"
VHOST_FILE="/etc/nginx/sites-available/$DOMAIN"
VHOST_LINK="/etc/nginx/sites-enabled/$DOMAIN"
SSL_DIR="/etc/nginx/ssl/$DOMAIN"

TITLE="${TITLE:-$DOMAIN}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@$DOMAIN}"
GENERATED_ADMIN_PASSWORD=0
if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
    GENERATED_ADMIN_PASSWORD=1
fi

# --- 2. Pick a free Redis DB index -------------------------------------------

USED_INDICES="$(cut -d'|' -f4 "$SITES_LIST" 2>/dev/null || true)"
REDIS_INDEX=""
for i in $(seq 0 15); do
    if ! grep -qx "$i" <<<"$USED_INDICES"; then
        REDIS_INDEX="$i"
        break
    fi
done
if [[ -z "$REDIS_INDEX" ]] && (( DRY_RUN == 0 )); then
    die "All 16 Redis DB indices (0-15) are in use — the shared Redis instance is out of room. Increase 'databases' in redis.conf or add a second Redis instance before adding more sites."
fi

if (( DRY_RUN )); then
    cat <<EOF

Dry run — no changes will be made. Plan for '$DOMAIN':

  Linux user:        $LINUX_USER (nologin, home=$SITE_BASE)
  Site directory:    $SITE_DIR
  PHP-FPM pool:      $POOL_FILE (socket $SOCKET, PHP $PHP_VERSION)
  Database:          $DB_NAME (user $DB_USER, scoped grant, random password)
  Redis DB index:    ${REDIS_INDEX:-NONE AVAILABLE (0-15 exhausted)}
  Nginx vhost:       $VHOST_FILE -> $VHOST_LINK
  TLS certificate:   Let's Encrypt via acme.sh, installed to $SSL_DIR
  WordPress title:   $TITLE
  Admin user/email:  $ADMIN_USER / $ADMIN_EMAIL
  Registry entry:    $SITES_LIST

EOF
    exit 0
fi

MYSQL_ROOT_PASSWORD="$(cat "$MYSQL_ROOT_PW_FILE")"

# --- Rollback bookkeeping -----------------------------------------------------
# On any failure we undo what we already created, in reverse order, and tell
# the user exactly what happened. The registry is only written as the very
# last step, so a failed run never leaves a half-registered site behind.

CREATED=()
mark() { CREATED+=("$1"); }

cleanup() {
    local rc=$?
    (( rc == 0 )) && return
    echo >&2
    echo "ERROR: create-site.sh failed (exit $rc). Rolling back what was created for '$DOMAIN'..." >&2
    local i item kind val
    for (( i = ${#CREATED[@]} - 1; i >= 0; i-- )); do
        item="${CREATED[$i]}"
        kind="${item%%:*}"
        val="${item#*:}"
        case "$kind" in
            nginx_site)
                rm -f "$VHOST_LINK" "$val"
                nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
                ;;
            fpm_pool)
                rm -f "$val"
                systemctl reload "php${PHP_VERSION}-fpm" >/dev/null 2>&1 || true
                ;;
            db)
                mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS \`$val\`;" 2>/dev/null || true
                ;;
            db_user)
                mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP USER IF EXISTS '$val'@'localhost';" 2>/dev/null || true
                ;;
            directory)
                rm -rf "$val" 2>/dev/null || true
                ;;
            linux_user)
                userdel -r "$val" 2>/dev/null || true
                ;;
        esac
        echo "  - rolled back: $item" >&2
    done
    echo "Rollback complete. $SITES_LIST was not modified." >&2
    exit "$rc"
}
trap cleanup ERR

# --- 3. Linux user -------------------------------------------------------------

log "Creating Linux user '$LINUX_USER' (nologin)"
useradd --system --no-create-home --shell /usr/sbin/nologin --home-dir "$SITE_BASE" --user-group "$LINUX_USER"
mark "linux_user:$LINUX_USER"

# --- 4. Site directory -----------------------------------------------------
# 750 owned by the site's own user:group; www-data (nginx) is added to that
# group so it can read/traverse static files, but only this pool's PHP
# workers (running as $LINUX_USER) can ever write to it.

log "Creating site directory $SITE_DIR"
mkdir -p "$SITE_DIR"
chown -R "$LINUX_USER:$LINUX_USER" "$SITE_BASE"
chmod 750 "$SITE_BASE" "$SITE_DIR"
mark "directory:$SITE_BASE"
usermod -aG "$LINUX_USER" www-data

# --- 5. PHP-FPM pool -----------------------------------------------------

log "Writing PHP-FPM pool $POOL_FILE"
sed \
    -e "s|__POOL_NAME__|$NORMALIZED|g" \
    -e "s|__USER__|$LINUX_USER|g" \
    -e "s|__GROUP__|$LINUX_USER|g" \
    -e "s|__SOCKET__|$SOCKET|g" \
    -e "s|__SITE_DIR__|$SITE_DIR|g" \
    "$TEMPLATE_DIR/php-fpm-pool.conf.template" > "$POOL_FILE"
mark "fpm_pool:$POOL_FILE"
systemctl reload "php${PHP_VERSION}-fpm"

# --- 6. MariaDB database + scoped user -----------------------------------

log "Creating database '$DB_NAME' and user '$DB_USER'"
DB_PASSWORD="$(openssl rand -hex 24)"
# Grants are scoped to this database only, host is 'localhost' (MariaDB
# already binds to 127.0.0.1 only) — no global privileges, no cross-database
# access, so a compromised site can't reach another site's data.
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<-SQL
    CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
SQL
mark "db:$DB_NAME"
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<-SQL
    CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
    GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
    FLUSH PRIVILEGES;
SQL
mark "db_user:$DB_USER"

# --- 7. Nginx vhost (HTTP only, needed for ACME validation) -----------------

log "Writing nginx vhost (HTTP) and enabling site"
sed \
    -e "s|__DOMAIN__|$DOMAIN|g" \
    -e "s|__SITE_DIR__|$SITE_DIR|g" \
    -e "s|__SOCKET__|$SOCKET|g" \
    "$TEMPLATE_DIR/nginx-vhost-http.conf.template" > "$VHOST_FILE"
mark "nginx_site:$VHOST_FILE"
ln -sf "$VHOST_FILE" "$VHOST_LINK"
nginx -t
systemctl reload nginx

# --- 8. Let's Encrypt certificate -----------------------------------------

log "Requesting Let's Encrypt certificate for $DOMAIN (webroot validation)"
mkdir -p "$SSL_DIR"
if ! "$ACME" --issue -d "$DOMAIN" -w "$SITE_DIR" --server letsencrypt; then
    die "Let's Encrypt validation failed for '$DOMAIN'. Most likely DNS for this domain doesn't point at this server's IP yet, or port 80 isn't reachable from the internet. Fix DNS/firewall and re-run create-site.sh."
fi
"$ACME" --install-cert -d "$DOMAIN" \
    --key-file "$SSL_DIR/privkey.pem" \
    --fullchain-file "$SSL_DIR/fullchain.pem" \
    --reloadcmd "systemctl reload nginx"

log "Switching nginx vhost to HTTPS + HTTP->HTTPS redirect"
sed \
    -e "s|__DOMAIN__|$DOMAIN|g" \
    -e "s|__SITE_DIR__|$SITE_DIR|g" \
    -e "s|__SOCKET__|$SOCKET|g" \
    -e "s|__SSL_DIR__|$SSL_DIR|g" \
    "$TEMPLATE_DIR/nginx-vhost-ssl.conf.template" > "$VHOST_FILE"
nginx -t
systemctl reload nginx

# --- 9. WordPress via WP-CLI -----------------------------------------------
# Runs as $LINUX_USER (not root) — sudo execs wp directly, so the target
# account's nologin shell doesn't block it.

WP="sudo -u $LINUX_USER -H wp --path=$SITE_DIR"

log "Downloading WordPress core"
$WP core download --quiet

log "Writing wp-config.php (DB + Redis object cache constants)"
$WP config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASSWORD" \
    --dbhost=127.0.0.1 --skip-check --quiet
$WP config set WP_REDIS_HOST 127.0.0.1 --type=constant --quiet
$WP config set WP_REDIS_PORT 6379 --raw --type=constant --quiet
$WP config set WP_REDIS_DATABASE "$REDIS_INDEX" --raw --type=constant --quiet

log "Installing WordPress"
$WP core install --url="https://$DOMAIN" --title="$TITLE" \
    --admin_user="$ADMIN_USER" --admin_password="$ADMIN_PASSWORD" \
    --admin_email="$ADMIN_EMAIL" --skip-email --quiet

log "Installing and enabling the Redis object cache"
$WP plugin install redis-cache --activate --quiet
$WP redis enable --quiet

# --- 10. Register the site -----------------------------------------------

echo "${DOMAIN}|${LINUX_USER}|${DB_NAME}|${REDIS_INDEX}|${PHP_VERSION}|$(date +%F)" >> "$SITES_LIST"

trap - ERR

# --- Summary -----------------------------------------------------------------

cat <<EOF

==> Site provisioned: https://$DOMAIN

  Admin URL:       https://$DOMAIN/wp-admin/
  Admin user:      $ADMIN_USER
$( (( GENERATED_ADMIN_PASSWORD )) && echo "  Admin password:  $ADMIN_PASSWORD  (generated — save this now, it is not stored anywhere)" )
  Database:        $DB_NAME
  Linux user:      $LINUX_USER
  Redis DB index:  $REDIS_INDEX
  PHP-FPM pool:    $POOL_FILE

EOF
