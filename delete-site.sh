#!/usr/bin/env bash
set -euo pipefail

# wpdeploy :: delete-site.sh <domain>
# Permanently removes a site provisioned by create-site.sh: Linux user
# (and its home/site directory), PHP-FPM pool, MariaDB database + user,
# nginx vhost, Let's Encrypt certificate, the site's dedicated Redis
# instance, and the registry entry. This is destructive and not
# reversible -- there is no backup step.

WPDEPLOY_DIR="/etc/wpdeploy"
SITES_LIST="$WPDEPLOY_DIR/sites.list"
MYSQL_ROOT_PW_FILE="$WPDEPLOY_DIR/.mysql_root"
ACME_HOME="/root/.acme.sh"

DRY_RUN=0
ASSUME_YES=0
DOMAIN_ARG=""

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo ./delete-site.sh <domain> [--yes] [--dry-run]

Permanently removes a site: Linux user, site directory, PHP-FPM pool,
MariaDB database/user, nginx vhost, Let's Encrypt certificate, the
site's dedicated Redis instance, and the registry entry. Cannot be
undone -- there is no backup step, so back up anything you need first.

  --yes, -y   skip the typed-confirmation prompt (for scripting)
  --dry-run   show what would be deleted without deleting anything
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) ASSUME_YES=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage ;;
        -*) die "Unknown flag: $1 (see --help)" ;;
        *) DOMAIN_ARG="$1"; shift ;;
    esac
done

[[ -n "$DOMAIN_ARG" ]] || usage
(( EUID == 0 )) || die "Must be run as root (sudo ./delete-site.sh <domain>)"
[[ -f "$SITES_LIST" ]] || die "$SITES_LIST not found -- run setup-server.sh first"

DOMAIN="${DOMAIN_ARG,,}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN#https://}"
DOMAIN="${DOMAIN#www.}"
DOMAIN="${DOMAIN%%/*}"

RECORD="$(grep "^${DOMAIN}|" "$SITES_LIST" 2>/dev/null || true)"
[[ -n "$RECORD" ]] || die "'$DOMAIN' is not in $SITES_LIST -- nothing to delete (see: tod site list)"

IFS='|' read -r _ LINUX_USER DB_NAME PHP_VERSION _ <<<"$RECORD"

SITE_BASE="/var/www/$DOMAIN"
POOL_FILE="/etc/php/${PHP_VERSION}/fpm/pool.d/${LINUX_USER}.conf"
VHOST_FILE="/etc/nginx/sites-available/$DOMAIN"
VHOST_LINK="/etc/nginx/sites-enabled/$DOMAIN"
SSL_DIR="/etc/nginx/ssl/$DOMAIN"
ACME_CERT_DIR="$ACME_HOME/$DOMAIN"

cat <<EOF

This will permanently delete:
  Linux user:       $LINUX_USER (and $SITE_BASE, including all files)
  Database:         $DB_NAME (and its user) -- all site data
  PHP-FPM pool:      $POOL_FILE
  Nginx vhost:       $VHOST_FILE
  TLS certificate:   $SSL_DIR (and $ACME_CERT_DIR)
  Redis instance:    redis-server@$LINUX_USER (stopped and removed)
  Registry entry:    $DOMAIN in $SITES_LIST

This cannot be undone. No backup is taken.
EOF

if (( DRY_RUN )); then
    echo "Dry run -- nothing deleted."
    exit 0
fi

if (( ASSUME_YES == 0 )); then
    read -rp "Type the domain to confirm deletion: " CONFIRM
    [[ "$CONFIRM" == "$DOMAIN" ]] || die "Confirmation didn't match '$DOMAIN' -- aborted, nothing was deleted."
fi

FAILED=()

log "Removing nginx vhost"
rm -f "$VHOST_LINK" "$VHOST_FILE"
if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
else
    warn "nginx config test failed after removing the vhost -- check 'nginx -t' manually"
    FAILED+=("nginx reload -- run 'nginx -t' and 'systemctl reload nginx' manually")
fi

log "Removing PHP-FPM pool"
if [[ -f "$POOL_FILE" ]]; then
    rm -f "$POOL_FILE"
    systemctl reload "php${PHP_VERSION}-fpm" 2>/dev/null || FAILED+=("php${PHP_VERSION}-fpm reload")
fi

log "Revoking and removing the TLS certificate"
if [[ -x "$ACME_HOME/acme.sh" ]]; then
    "$ACME_HOME/acme.sh" --remove -d "$DOMAIN" >/dev/null 2>&1 || true
fi
rm -rf "$ACME_CERT_DIR" "$SSL_DIR"

log "Dropping the database and database user"
if [[ -f "$MYSQL_ROOT_PW_FILE" ]]; then
    MYSQL_ROOT_PASSWORD="$(cat "$MYSQL_ROOT_PW_FILE")"
    mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`; DROP USER IF EXISTS '${LINUX_USER}'@'localhost';" \
        || FAILED+=("MariaDB: drop database \`$DB_NAME\` / user '$LINUX_USER' manually")
else
    warn "No MariaDB root password on file -- skipping database cleanup"
    FAILED+=("MariaDB: drop database \`$DB_NAME\` / user '$LINUX_USER' manually (no root password file)")
fi

log "Stopping and removing the Redis instance"
systemctl disable --now "redis-server@${LINUX_USER}" >/dev/null 2>&1 \
    || FAILED+=("systemctl disable --now redis-server@${LINUX_USER} manually")
rm -f "/etc/redis/redis-${LINUX_USER}.conf" "/var/log/redis/redis-server-${LINUX_USER}.log"

log "Removing the Linux user and site directory"
if id "$LINUX_USER" >/dev/null 2>&1; then
    userdel -r "$LINUX_USER" 2>/dev/null || FAILED+=("userdel -r $LINUX_USER")
fi
rm -rf "$SITE_BASE"

log "Removing the registry entry"
grep -v "^${DOMAIN}|" "$SITES_LIST" > "$SITES_LIST.tmp" && mv "$SITES_LIST.tmp" "$SITES_LIST"

if (( ${#FAILED[@]} > 0 )); then
    warn "'$DOMAIN' was removed from the registry, but some cleanup steps need manual attention:"
    for f in "${FAILED[@]}"; do
        printf '  - %s\n' "$f" >&2
    done
    exit 1
fi

log "'$DOMAIN' fully removed"
