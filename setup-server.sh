#!/usr/bin/env bash
set -euo pipefail

# wpdeploy :: setup-server.sh
# One-time bootstrap of a fresh Ubuntu 24.04 VPS for isolated WordPress
# hosting. Safe to re-run: every step checks current state before acting.

WPDEPLOY_DIR="/etc/wpdeploy"
SITES_LIST="$WPDEPLOY_DIR/sites.list"
MYSQL_ROOT_PW_FILE="$WPDEPLOY_DIR/.mysql_root"
ACME_HOME="/root/.acme.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PHP_VERSION="8.3"
ACME_EMAIL=""
MYSQL_ROOT_PASSWORD=""

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo ./setup-server.sh [--php-version 8.3] [--acme-email you@example.com] [--mysql-root-password 'secret']

Bootstraps this server for wpdeploy: nginx, PHP-FPM, MariaDB, Redis,
WP-CLI, acme.sh, ufw, fail2ban. Run once per server. Safe to re-run.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --php-version) PHP_VERSION="$2"; shift 2 ;;
        --acme-email) ACME_EMAIL="$2"; shift 2 ;;
        --mysql-root-password) MYSQL_ROOT_PASSWORD="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Must be run as root (sudo ./setup-server.sh)"

INSTALLED=()   # human-readable summary lines, printed at the end

log "Preparing /etc/wpdeploy registry"
mkdir -p "$WPDEPLOY_DIR"
chmod 700 "$WPDEPLOY_DIR"
touch "$SITES_LIST"
chmod 600 "$SITES_LIST"
INSTALLED+=("Registry: $WPDEPLOY_DIR (sites.list)")

log "Updating apt package index"
apt-get update -qq

log "Installing base packages"
apt-get install -y -qq software-properties-common curl wget gnupg2 ca-certificates \
    lsb-release ufw fail2ban unzip >/dev/null
INSTALLED+=("Base packages: curl, ufw, fail2ban, unzip, etc.")

# --- PHP-FPM + extensions ---------------------------------------------------
log "Ensuring ondrej/php PPA is present (for a specific, up-to-date PHP version)"
if ! grep -Rq "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
    add-apt-repository -y ppa:ondrej/php >/dev/null
    apt-get update -qq
fi

PHP_PKGS=(
    "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-common"
    "php${PHP_VERSION}-mysqli" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-gd"
    "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-zip"
    "php${PHP_VERSION}-imagick" "php${PHP_VERSION}-redis" "php${PHP_VERSION}-opcache"
)
if ! dpkg -s "php${PHP_VERSION}-fpm" >/dev/null 2>&1; then
    log "Installing PHP ${PHP_VERSION}-FPM and WordPress-required extensions"
    apt-get install -y -qq "${PHP_PKGS[@]}"
else
    log "PHP ${PHP_VERSION}-FPM already installed, skipping"
fi
systemctl enable --now "php${PHP_VERSION}-fpm" >/dev/null
INSTALLED+=("PHP ${PHP_VERSION}-FPM + mysqli, curl, gd, mbstring, xml, zip, imagick, redis")

# --- nginx -------------------------------------------------------------------
if ! dpkg -s nginx >/dev/null 2>&1; then
    log "Installing nginx"
    apt-get install -y -qq nginx
else
    log "nginx already installed, skipping"
fi
systemctl enable --now nginx >/dev/null
INSTALLED+=("nginx")

# --- MariaDB -------------------------------------------------------------------
if ! dpkg -s mariadb-server >/dev/null 2>&1; then
    log "Installing MariaDB server"
    apt-get install -y -qq mariadb-server
else
    log "MariaDB already installed, skipping"
fi
systemctl enable --now mariadb >/dev/null

log "Binding MariaDB to 127.0.0.1 only"
MARIADB_CONF="/etc/mysql/mariadb.conf.d/50-server.cnf"
if [[ -f "$MARIADB_CONF" ]] && ! grep -qE '^\s*bind-address\s*=\s*127\.0\.0\.1' "$MARIADB_CONF"; then
    if grep -qE '^\s*bind-address' "$MARIADB_CONF"; then
        sed -i 's/^\s*bind-address.*/bind-address = 127.0.0.1/' "$MARIADB_CONF"
    else
        printf '\n[mysqld]\nbind-address = 127.0.0.1\n' >> "$MARIADB_CONF"
    fi
    systemctl restart mariadb
fi

log "Securing MariaDB (equivalent of mysql_secure_installation)"
if [[ -f "$MYSQL_ROOT_PW_FILE" ]]; then
    MYSQL_ROOT_PASSWORD="$(cat "$MYSQL_ROOT_PW_FILE")"
    if mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
        log "MariaDB root password already configured, skipping"
    else
        warn "Stored root password no longer authenticates; re-securing"
        rm -f "$MYSQL_ROOT_PW_FILE"
    fi
fi

if [[ ! -f "$MYSQL_ROOT_PW_FILE" ]]; then
    if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
        read -rsp "Set MariaDB root password (leave blank to auto-generate): " input_pw
        echo
        MYSQL_ROOT_PASSWORD="${input_pw:-$(openssl rand -base64 24)}"
    fi
    # DROP USER is used (rather than editing mysql.user directly) because it
    # works regardless of MariaDB's internal grant-table layout for a given
    # version, and IF EXISTS keeps this idempotent.
    mysql -uroot <<-SQL
        DROP USER IF EXISTS ''@'localhost';
        DROP USER IF EXISTS ''@'$(hostname)';
        DROP DATABASE IF EXISTS test;
        ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
        FLUSH PRIVILEGES;
SQL
    printf '%s' "$MYSQL_ROOT_PASSWORD" > "$MYSQL_ROOT_PW_FILE"
    chmod 600 "$MYSQL_ROOT_PW_FILE"
fi
INSTALLED+=("MariaDB, bound to 127.0.0.1, root password in $MYSQL_ROOT_PW_FILE (root-only)")

# --- Redis -------------------------------------------------------------------
if ! dpkg -s redis-server >/dev/null 2>&1; then
    log "Installing Redis"
    apt-get install -y -qq redis-server
else
    log "Redis already installed, skipping"
fi

REDIS_CONF="/etc/redis/redis.conf"
REDIS_CHANGED=0
if [[ -f "$REDIS_CONF" ]]; then
    if ! grep -qE '^bind 127\.0\.0\.1' "$REDIS_CONF"; then
        sed -i 's/^bind .*/bind 127.0.0.1 -::1/' "$REDIS_CONF"
        REDIS_CHANGED=1
    fi
    if ! grep -qE '^supervised systemd' "$REDIS_CONF"; then
        if grep -qE '^supervised ' "$REDIS_CONF"; then
            sed -i 's/^supervised .*/supervised systemd/' "$REDIS_CONF"
        else
            echo "supervised systemd" >> "$REDIS_CONF"
        fi
        REDIS_CHANGED=1
    fi
fi
systemctl enable redis-server >/dev/null
if (( REDIS_CHANGED )) || ! systemctl is-active --quiet redis-server; then
    systemctl restart redis-server
fi
INSTALLED+=("Redis, bound to 127.0.0.1 (shared instance, per-site DB index 0-15)")

# --- WP-CLI -------------------------------------------------------------------
if ! command -v wp >/dev/null 2>&1; then
    log "Installing WP-CLI"
    curl -sSL -o /usr/local/bin/wp \
        https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x /usr/local/bin/wp
else
    log "WP-CLI already installed, skipping"
fi
INSTALLED+=("WP-CLI ($(wp --version --allow-root 2>/dev/null | head -1))")

# --- acme.sh -------------------------------------------------------------------
if [[ ! -x "$ACME_HOME/acme.sh" ]]; then
    log "Installing acme.sh"
    if [[ -n "$ACME_EMAIL" ]]; then
        curl -sSL https://get.acme.sh | sh -s email="$ACME_EMAIL"
    else
        curl -sSL https://get.acme.sh | sh
    fi
else
    log "acme.sh already installed, skipping"
fi
"$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
"$ACME_HOME/acme.sh" --install-cronjob >/dev/null 2>&1 || true
ln -sf "$ACME_HOME/acme.sh" /usr/local/bin/acme.sh
INSTALLED+=("acme.sh, default CA = Let's Encrypt, auto-renewal cron installed")

# --- ufw -------------------------------------------------------------------
log "Configuring ufw (22, 80, 443 only)"
ufw allow 22/tcp >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable >/dev/null
INSTALLED+=("ufw: allow 22, 80, 443; deny everything else")

# --- fail2ban -------------------------------------------------------------------
log "Configuring fail2ban (sshd + nginx)"
{
    echo "[sshd]"
    echo "enabled = true"
    echo
    echo "[nginx-http-auth]"
    echo "enabled = true"
    if [[ -f /etc/fail2ban/filter.d/nginx-botsearch.conf ]]; then
        echo
        echo "[nginx-botsearch]"
        echo "enabled = true"
    fi
} > /etc/fail2ban/jail.local
systemctl enable fail2ban >/dev/null
systemctl restart fail2ban
INSTALLED+=("fail2ban: sshd + nginx-http-auth jails enabled")

# --- tod command -------------------------------------------------------------
if [[ -x "$SCRIPT_DIR/tod" ]]; then
    ln -sf "$SCRIPT_DIR/tod" /usr/local/bin/tod
    INSTALLED+=("tod command: linked into /usr/local/bin/tod (tod help)")
fi

log "Setup complete"
printf '\nInstalled/configured:\n'
for line in "${INSTALLED[@]}"; do
    printf '  - %s\n' "$line"
done
printf '\nNext: sudo tod site create <domain> to provision a site.\n'
