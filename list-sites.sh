#!/usr/bin/env bash
set -euo pipefail

# wpdeploy :: list-sites.sh [--verbose]
# Prints the sites registered in /etc/wpdeploy/sites.list.

SITES_LIST="/etc/wpdeploy/sites.list"
VERBOSE=0

usage() {
    cat <<EOF
Usage: ./list-sites.sh [--verbose]

  --verbose   also show disk usage per site and TLS certificate expiry
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

[[ -f "$SITES_LIST" ]] || { echo "No registry found at $SITES_LIST — run setup-server.sh first." >&2; exit 1; }
[[ -s "$SITES_LIST" ]] || { echo "No sites provisioned yet."; exit 0; }

if (( VERBOSE )); then
    printf "%-30s %-18s %-22s %-6s %-6s %-12s %-8s %-25s\n" \
        "DOMAIN" "LINUX USER" "DB NAME" "REDIS" "PHP" "CREATED" "DISK" "CERT EXPIRES"
else
    printf "%-30s %-18s %-22s %-6s %-6s %-12s\n" \
        "DOMAIN" "LINUX USER" "DB NAME" "REDIS" "PHP" "CREATED"
fi

while IFS='|' read -r domain user db redis php created; do
    [[ -z "$domain" ]] && continue
    if (( VERBOSE )); then
        disk="n/a"
        [[ -d "/var/www/$domain" ]] && disk="$(du -sh "/var/www/$domain" 2>/dev/null | cut -f1)"
        expiry="n/a"
        cert="/etc/nginx/ssl/$domain/fullchain.pem"
        [[ -f "$cert" ]] && expiry="$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)"
        printf "%-30s %-18s %-22s %-6s %-6s %-12s %-8s %-25s\n" \
            "$domain" "$user" "$db" "$redis" "$php" "$created" "$disk" "$expiry"
    else
        printf "%-30s %-18s %-22s %-6s %-6s %-12s\n" \
            "$domain" "$user" "$db" "$redis" "$php" "$created"
    fi
done < "$SITES_LIST"
