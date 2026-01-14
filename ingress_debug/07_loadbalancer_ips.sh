#!/bin/bash
# LoadBalancer and External IP Mapping
# Usage: ./07_loadbalancer_ips.sh [context]

set -euo pipefail

CONTEXT="${1:-}"
KUBECTL="kubectl"

if [[ -n "$CONTEXT" ]]; then
    KUBECTL="kubectl --context=$CONTEXT"
fi

echo "=========================================="
echo "LOADBALANCER & EXTERNAL IP DEBUG"
echo "Context: ${CONTEXT:-current}"
echo "=========================================="

echo ""
echo "--- All LoadBalancer Services ---"
$KUBECTL get svc --all-namespaces -o wide | grep -E "LoadBalancer" || echo "None found"

echo ""
echo "--- External IPs for Ingress Controllers ---"
echo "NAMESPACE                     SERVICE                       EXTERNAL-IP                   PORTS"
$KUBECTL get svc --all-namespaces -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | select(.metadata.name | test("nginx|ingress"; "i")) | "\(.metadata.namespace)\t\(.metadata.name)\t\(.status.loadBalancer.ingress[0].ip // .status.loadBalancer.ingress[0].hostname // "pending")\t\(.spec.ports | map("\(.port):\(.nodePort // "n/a")") | join(","))"' 2>/dev/null || echo "jq not available or no LB services"

echo ""
echo "--- NodePort Services (if any) ---"
$KUBECTL get svc --all-namespaces -o wide | grep -E "NodePort" | grep -iE "(nginx|ingress)" || echo "None found"

echo ""
echo "--- Mapping: Which controller serves which IP? ---"
echo ""
echo "Run these curls to identify which controller responds:"
for ip in $($KUBECTL get svc --all-namespaces -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer") | .status.loadBalancer.ingress[0].ip // .status.loadBalancer.ingress[0].hostname // empty' 2>/dev/null); do
    echo "curl -sI http://$ip | grep -i server"
done
