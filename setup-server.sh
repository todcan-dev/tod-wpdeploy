#!/usr/bin/env bash
set -euo pipefail

# wpdeploy :: setup-server.sh
# One-time bootstrap of a fresh Ubuntu 24.04 VPS for isolated WordPress
# hosting. Safe to re-run: every step checks current state before acting.

WPDEPLOY_DIR="/etc/wpdeploy"
SITES_LIST="$WPDEPLOY_DIR/sites.list"
MYSQL_ROOT_PW_FILE="$WPDEPLOY_DIR/.mysql_root"
CONFIG_FILE="$WPDEPLOY_DIR/config"
ACME_HOME="/root/.acme.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PHP_VERSION="8.3"
ACME_EMAIL=""
MYSQL_ROOT_PASSWORD=""
ADMIN_USER=""
ADMIN_EMAIL=""
SSH_ALLOW_IP=""

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: sudo ./setup-server.sh [--php-version 8.3] [--acme-email you@example.com]
                               [--mysql-root-password 'secret']
                               [--admin-user name] [--admin-email you@example.com]
                               [--ssh-allow-ip <ip-or-cidr>|any]

Bootstraps this server for wpdeploy: nginx, PHP-FPM, MariaDB, Redis,
WP-CLI, acme.sh, ufw, fail2ban. Run once per server. Safe to re-run.

Run it from a real terminal and it prompts for whatever wasn't passed as
a flag: WordPress admin username/email (the default every
'tod site create' uses afterward) and whether to restrict SSH to your
current IP. Piped/non-interactive runs skip all prompts and fall back to
flag values or safe defaults (SSH stays open to everyone unless
--ssh-allow-ip is given).

--admin-user/--admin-email set the server-wide default WordPress admin
identity: every 'tod site create' afterward uses them unless overridden
per-site with its own --admin-user/--admin-email.

--ssh-allow-ip restricts SSH (port 22) to one IP/CIDR instead of the
whole internet; pass 'any' to explicitly leave it open. If that address
ever changes, you'll need console access from your VPS provider to get
back in -- re-run with --ssh-allow-ip any (or the new address) to fix it.
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --php-version) PHP_VERSION="$2"; shift 2 ;;
        --acme-email) ACME_EMAIL="$2"; shift 2 ;;
        --mysql-root-password) MYSQL_ROOT_PASSWORD="$2"; shift 2 ;;
        --admin-user) ADMIN_USER="$2"; shift 2 ;;
        --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
        --ssh-allow-ip) SSH_ALLOW_IP="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) die "Unknown argument: $1 (see --help)" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Must be run as root (sudo ./setup-server.sh)"

# --- Interactive setup (only when connected to a real terminal) ------------
# Flags always win; this only fills in what wasn't passed. A piped or
# non-interactive run (install.sh, cron, CI) skips straight to the
# fallback resolution below with no prompts at all.
DEFAULT_ADMIN_USER=""
DEFAULT_ADMIN_EMAIL=""
PREV_SSH_ALLOW_IP=""
# shellcheck source=/dev/null
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

if [[ -t 0 ]]; then
    if [[ -z "$ADMIN_USER" ]]; then
        read -rp "WordPress admin username for new sites [${DEFAULT_ADMIN_USER:-admin}]: " ADMIN_USER || true
    fi
    if [[ -z "$ADMIN_EMAIL" ]]; then
        read -rp "WordPress admin email for new sites, also used for Let's Encrypt notices [${DEFAULT_ADMIN_EMAIL:-none}]: " ADMIN_EMAIL || true
    fi
    if [[ -z "$SSH_ALLOW_IP" ]]; then
        # $SSH_CLIENT is almost never present here: this script always runs
        # via sudo, and sudo's default env_reset strips it before we ever
        # see it. Fall back to `who`, keyed on $SUDO_USER (which sudo does
        # preserve) -- that reads the connecting address straight out of
        # utmp, independent of what sudo does to the environment.
        DETECTED_IP="$(awk '{print $1}' <<<"${SSH_CLIENT:-}")"
        if [[ -z "$DETECTED_IP" && -n "${SUDO_USER:-}" ]]; then
            DETECTED_IP="$(who | awk -v u="$SUDO_USER" '$1==u { for(i=1;i<=NF;i++) if ($i ~ /^\(.*\)$/) { gsub(/[()]/,"",$i); print $i; exit } }')"
        fi
        # who prints "(:0)" for a local console login, not a real address --
        # only trust something IP-shaped, otherwise treat it as undetected.
        [[ "$DETECTED_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || DETECTED_IP=""
        if [[ -n "$DETECTED_IP" ]]; then
            read -rp "Restrict SSH (port 22) to your current IP ($DETECTED_IP)? [Y/n, or type a different IP/CIDR]: " ssh_answer || true
            case "${ssh_answer,,}" in
                ""|y|yes) SSH_ALLOW_IP="$DETECTED_IP" ;;
                n|no)     SSH_ALLOW_IP="any" ;;
                *)        SSH_ALLOW_IP="$ssh_answer" ;;
            esac
        else
            read -rp "Restrict SSH (port 22) to an IP/CIDR? Leave blank to allow from anywhere [${PREV_SSH_ALLOW_IP:-any}]: " SSH_ALLOW_IP || true
        fi
    fi
fi

ADMIN_USER="${ADMIN_USER:-${DEFAULT_ADMIN_USER:-admin}}"
ADMIN_EMAIL="${ADMIN_EMAIL:-$DEFAULT_ADMIN_EMAIL}"
SSH_ALLOW_IP="${SSH_ALLOW_IP:-${PREV_SSH_ALLOW_IP:-any}}"
ACME_EMAIL="${ACME_EMAIL:-$ADMIN_EMAIL}"

if [[ "$SSH_ALLOW_IP" != "any" ]]; then
    warn "SSH will be restricted to $SSH_ALLOW_IP -- if that address ever changes you'll need console access from your VPS provider to reconnect. Re-run with --ssh-allow-ip any to open it back up."
fi

INSTALLED=()   # human-readable summary lines, printed at the end

log "Preparing /etc/wpdeploy registry"
mkdir -p "$WPDEPLOY_DIR"
chmod 700 "$WPDEPLOY_DIR"
touch "$SITES_LIST"
chmod 600 "$SITES_LIST"
INSTALLED+=("Registry: $WPDEPLOY_DIR (sites.list)")

# Persisted now (before any real provisioning) so a re-run after a
# transient failure doesn't re-prompt for what was already answered.
{
    [[ -n "$ADMIN_USER" ]] && echo "DEFAULT_ADMIN_USER='$ADMIN_USER'"
    [[ -n "$ADMIN_EMAIL" ]] && echo "DEFAULT_ADMIN_EMAIL='$ADMIN_EMAIL'"
    echo "PREV_SSH_ALLOW_IP='$SSH_ALLOW_IP'"
} > "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"
[[ -n "$ADMIN_USER" || -n "$ADMIN_EMAIL" ]] && INSTALLED+=("Default WP admin for new sites: ${ADMIN_USER:-admin} <${ADMIN_EMAIL:-not set}>")

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
    # Auto-generated unless --mysql-root-password was passed -- no prompt,
    # so this step never blocks waiting for input (matches every other
    # generated credential in wpdeploy: never asked, always generated).
    MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-$(openssl rand -base64 24)}"
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
# Installed here for the package + its systemd redis-server@.service
# template + default /etc/redis/redis.conf, but no shared instance is
# actually used by any site -- create-site.sh starts a dedicated
# redis-server@<site> instance per site instead (own unix socket, own
# random requirepass), so one compromised site can't read or flush
# another site's cache. The default (non-templated) instance is disabled
# so there's no always-on, unauthenticated Redis anyone could reach.
if ! dpkg -s redis-server >/dev/null 2>&1; then
    log "Installing Redis"
    apt-get install -y -qq redis-server
else
    log "Redis already installed, skipping"
fi

REDIS_CONF="/etc/redis/redis.conf"
if [[ -f "$REDIS_CONF" ]] && ! grep -qE '^bind 127\.0\.0\.1' "$REDIS_CONF"; then
    sed -i 's/^bind .*/bind 127.0.0.1 -::1/' "$REDIS_CONF"
fi
systemctl disable --now redis-server >/dev/null 2>&1 || true
INSTALLED+=("Redis installed (per-site instances started by 'tod site create'; default shared instance disabled)")

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
log "Configuring ufw (SSH: $SSH_ALLOW_IP, plus 80, 443)"
if [[ -n "$PREV_SSH_ALLOW_IP" && "$PREV_SSH_ALLOW_IP" != "$SSH_ALLOW_IP" ]]; then
    log "SSH access rule changed ($PREV_SSH_ALLOW_IP -> $SSH_ALLOW_IP), removing the old rule"
    if [[ "$PREV_SSH_ALLOW_IP" == "any" ]]; then
        ufw delete allow 22/tcp >/dev/null 2>&1 || true
    else
        ufw delete allow from "$PREV_SSH_ALLOW_IP" to any port 22 proto tcp >/dev/null 2>&1 || true
    fi
fi
if [[ "$SSH_ALLOW_IP" == "any" ]]; then
    ufw allow 22/tcp >/dev/null
else
    ufw allow from "$SSH_ALLOW_IP" to any port 22 proto tcp >/dev/null
fi
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw --force enable >/dev/null
INSTALLED+=("ufw: SSH restricted to $SSH_ALLOW_IP; 80, 443 open; deny everything else")

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
