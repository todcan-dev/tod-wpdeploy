#!/usr/bin/env bash
set -euo pipefail

# wpdeploy :: install.sh
# One-command installer: gets wpdeploy onto this machine and puts `tod`
# on your PATH. Mirrors WordOps' `wget wo && sudo bash wo` pattern —
# download this file first, then run it, rather than piping curl straight
# into bash, so a truncated download fails loudly instead of executing a
# half-downloaded script.
#
#   curl -fsSL https://raw.githubusercontent.com/todcan-dev/tod-wpdeploy/main/install.sh -o install.sh
#   sudo bash install.sh
#
# Then: sudo tod setup --php-version 8.3 --acme-email you@example.com

REPO_URL="https://github.com/todcan-dev/tod-wpdeploy.git"
INSTALL_DIR="/opt/wpdeploy"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || die "Must be run as root (sudo bash install.sh)"

if ! command -v git >/dev/null 2>&1; then
    log "Installing git"
    apt-get update -qq
    apt-get install -y -qq git
fi

if [[ -d "$INSTALL_DIR/.git" ]]; then
    log "wpdeploy already present at $INSTALL_DIR, updating"
    git -C "$INSTALL_DIR" pull --ff-only
else
    log "Cloning wpdeploy to $INSTALL_DIR"
    git clone -q "$REPO_URL" "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR"/setup-server.sh "$INSTALL_DIR"/create-site.sh \
    "$INSTALL_DIR"/list-sites.sh "$INSTALL_DIR"/tod
ln -sf "$INSTALL_DIR/tod" /usr/local/bin/tod

log "wpdeploy installed at $INSTALL_DIR. 'tod' is on your PATH."
printf '\nNext: sudo tod setup --php-version 8.3 --acme-email you@example.com\n'
