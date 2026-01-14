#!/bin/bash
# Ingress Resources Debugging
# Usage: ./03_ingresses.sh [context] [namespace]

set -euo pipefail

CONTEXT="${1:-}"
NAMESPACE="${2:-}"
KUBECTL="kubectl"

if [[ -n "$CONTEXT" ]]; then
    KUBECTL="kubectl --context=$CONTEXT"
fi

NS_FLAG=""
if [[ -n "$NAMESPACE" ]]; then
    NS_FLAG="-n $NAMESPACE"
else
    NS_FLAG="--all-namespaces"
fi

echo "=========================================="
echo "INGRESS RESOURCES DEBUG"
echo "Context: ${CONTEXT:-current}"
echo "Namespace: ${NAMESPACE:-all}"
echo "=========================================="

echo ""
echo "--- All Ingresses ---"
$KUBECTL get ingress $NS_FLAG -o wide

echo ""
echo "--- Ingress with Class Mapping ---"
echo "NAMESPACE                     NAME                          CLASS                         HOSTS"
$KUBECTL get ingress $NS_FLAG -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.ingressClassName}{"\t"}{.spec.rules[*].host}{"\n"}{end}'

echo ""
echo "--- Ingresses with deprecated annotation (kubernetes.io/ingress.class) ---"
$KUBECTL get ingress $NS_FLAG -o json | jq -r '.items[] | select(.metadata.annotations["kubernetes.io/ingress.class"] != null) | "\(.metadata.namespace)/\(.metadata.name): \(.metadata.annotations["kubernetes.io/ingress.class"])"' 2>/dev/null || echo "No deprecated annotations found or jq not available"

echo ""
echo "--- Ingress Details (describe) ---"
if [[ -n "$NAMESPACE" ]]; then
    for ing in $($KUBECTL get ingress -n "$NAMESPACE" -o name 2>/dev/null); do
        echo ""
        echo "=== $ing ==="
        $KUBECTL describe "$ing" -n "$NAMESPACE"
    done
else
    echo "(Run with namespace argument to see describe output)"
fi
