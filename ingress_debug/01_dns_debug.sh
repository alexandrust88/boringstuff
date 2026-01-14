#!/bin/bash
# DNS and External Resolution Debugging
# Usage: ./01_dns_debug.sh <hostname>

set -euo pipefail

HOSTNAME="${1:-}"

if [[ -z "$HOSTNAME" ]]; then
    echo "Usage: $0 <hostname>"
    echo "Example: $0 argocd.example.com"
    exit 1
fi

echo "=========================================="
echo "DNS DEBUG FOR: $HOSTNAME"
echo "=========================================="

echo ""
echo "--- nslookup ---"
nslookup "$HOSTNAME" || true

echo ""
echo "--- dig (short) ---"
dig +short "$HOSTNAME" || true

echo ""
echo "--- dig (full) ---"
dig "$HOSTNAME" || true

echo ""
echo "--- host ---"
host "$HOSTNAME" || true

echo ""
echo "--- Resolved IPs ---"
getent hosts "$HOSTNAME" 2>/dev/null || echo "getent not available or no result"

echo ""
echo "--- Curl Headers (without following redirects) ---"
curl -sI --connect-timeout 5 "https://$HOSTNAME" 2>/dev/null | head -20 || \
curl -sI --connect-timeout 5 "http://$HOSTNAME" 2>/dev/null | head -20 || \
echo "Connection failed"

echo ""
echo "--- Curl with verbose connection info ---"
curl -sv --connect-timeout 5 "https://$HOSTNAME" 2>&1 | grep -E "(Trying|Connected|SSL|Host:|Server:)" || true
