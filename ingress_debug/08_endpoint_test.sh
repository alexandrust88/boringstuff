#!/bin/bash
# Endpoint Connectivity Test
# Usage: ./08_endpoint_test.sh <hostname> [expected-controller-ip]

set -euo pipefail

HOSTNAME="${1:-}"
EXPECTED_IP="${2:-}"

if [[ -z "$HOSTNAME" ]]; then
    echo "Usage: $0 <hostname> [expected-controller-ip]"
    echo "Example: $0 argocd.example.com 10.0.0.1"
    exit 1
fi

echo "=========================================="
echo "ENDPOINT CONNECTIVITY TEST"
echo "Hostname: $HOSTNAME"
echo "Expected IP: ${EXPECTED_IP:-not specified}"
echo "=========================================="

echo ""
echo "--- DNS Resolution ---"
RESOLVED_IP=$(dig +short "$HOSTNAME" | head -1)
echo "Resolved IP: $RESOLVED_IP"

if [[ -n "$EXPECTED_IP" ]] && [[ "$RESOLVED_IP" != "$EXPECTED_IP" ]]; then
    echo "WARNING: Resolved IP does not match expected IP!"
    echo "This might be your problem - DNS is pointing to wrong controller"
fi

echo ""
echo "--- HTTP Response (no SSL verify) ---"
curl -skI --connect-timeout 5 "https://$HOSTNAME" 2>/dev/null | head -15 || echo "HTTPS failed"

echo ""
echo "--- Server Header ---"
SERVER=$(curl -skI --connect-timeout 5 "https://$HOSTNAME" 2>/dev/null | grep -i "^server:" || echo "No server header")
echo "$SERVER"

echo ""
echo "--- Direct IP Test (bypass DNS) ---"
if [[ -n "$EXPECTED_IP" ]]; then
    echo "Testing direct connection to $EXPECTED_IP with Host: $HOSTNAME"
    curl -skI --connect-timeout 5 --resolve "$HOSTNAME:443:$EXPECTED_IP" "https://$HOSTNAME" 2>/dev/null | head -15 || echo "Direct HTTPS failed"
fi

echo ""
echo "--- Certificate Info ---"
echo | openssl s_client -servername "$HOSTNAME" -connect "$HOSTNAME:443" 2>/dev/null | openssl x509 -noout -subject -issuer 2>/dev/null || echo "Could not get cert info"

echo ""
echo "--- TLS SNI Check ---"
echo "Checking what cert is served for SNI: $HOSTNAME"
echo | openssl s_client -servername "$HOSTNAME" -connect "$HOSTNAME:443" 2>/dev/null | grep -E "(subject|issuer|CN)" | head -5 || true
