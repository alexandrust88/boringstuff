#!/bin/bash
# Full Debug Run - Collects everything
# Usage: ./09_full_debug.sh <hostname> [context] [namespace]

set -euo pipefail

HOSTNAME="${1:-}"
CONTEXT="${2:-}"
NAMESPACE="${3:-}"

if [[ -z "$HOSTNAME" ]]; then
    echo "Usage: $0 <hostname> [context] [namespace]"
    echo "Example: $0 argocd.example.com my-cluster argocd"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/debug_output_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT_DIR"

echo "=========================================="
echo "FULL INGRESS DEBUG"
echo "Hostname: $HOSTNAME"
echo "Context: ${CONTEXT:-current}"
echo "Namespace: ${NAMESPACE:-all}"
echo "Output: $OUTPUT_DIR"
echo "=========================================="

echo ""
echo "Running all debug scripts..."

echo "[1/8] DNS Debug..."
"$SCRIPT_DIR/01_dns_debug.sh" "$HOSTNAME" > "$OUTPUT_DIR/01_dns.txt" 2>&1 || true

echo "[2/8] Ingress Classes..."
"$SCRIPT_DIR/02_ingress_classes.sh" "$CONTEXT" > "$OUTPUT_DIR/02_classes.txt" 2>&1 || true

echo "[3/8] Ingress Resources..."
"$SCRIPT_DIR/03_ingresses.sh" "$CONTEXT" "$NAMESPACE" > "$OUTPUT_DIR/03_ingresses.txt" 2>&1 || true

echo "[4/8] Ingress Controllers..."
"$SCRIPT_DIR/04_ingress_controllers.sh" "$CONTEXT" > "$OUTPUT_DIR/04_controllers.txt" 2>&1 || true

echo "[5/8] LoadBalancer IPs..."
"$SCRIPT_DIR/07_loadbalancer_ips.sh" "$CONTEXT" > "$OUTPUT_DIR/05_loadbalancers.txt" 2>&1 || true

echo "[6/8] Endpoint Test..."
"$SCRIPT_DIR/08_endpoint_test.sh" "$HOSTNAME" > "$OUTPUT_DIR/06_endpoint.txt" 2>&1 || true

echo "[7/8] Controller Logs (last 50 lines)..."
"$SCRIPT_DIR/06_controller_logs.sh" "$CONTEXT" 50 > "$OUTPUT_DIR/07_logs.txt" 2>&1 || true

echo "[8/8] Generating Summary..."
cat > "$OUTPUT_DIR/00_summary.txt" << EOF
INGRESS DEBUG SUMMARY
=====================
Generated: $(date)
Hostname: $HOSTNAME
Context: ${CONTEXT:-current}
Namespace: ${NAMESPACE:-all}

Quick Checks:
-------------
EOF

# Add quick findings to summary
echo "DNS Resolution:" >> "$OUTPUT_DIR/00_summary.txt"
dig +short "$HOSTNAME" >> "$OUTPUT_DIR/00_summary.txt" 2>&1 || echo "Failed" >> "$OUTPUT_DIR/00_summary.txt"

echo "" >> "$OUTPUT_DIR/00_summary.txt"
echo "Ingress Classes:" >> "$OUTPUT_DIR/00_summary.txt"
kubectl ${CONTEXT:+--context=$CONTEXT} get ingressclass -o custom-columns=NAME:.metadata.name,CONTROLLER:.spec.controller,DEFAULT:.metadata.annotations."ingressclass\.kubernetes\.io/is-default-class" 2>/dev/null >> "$OUTPUT_DIR/00_summary.txt" || echo "Failed" >> "$OUTPUT_DIR/00_summary.txt"

echo ""
echo "=========================================="
echo "DEBUG COMPLETE"
echo "Output saved to: $OUTPUT_DIR"
echo "Start by reviewing: $OUTPUT_DIR/00_summary.txt"
echo "=========================================="
