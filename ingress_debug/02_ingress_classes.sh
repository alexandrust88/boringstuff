#!/bin/bash
# Ingress Classes Debugging
# Usage: ./02_ingress_classes.sh [context]

set -euo pipefail

CONTEXT="${1:-}"
KUBECTL="kubectl"

if [[ -n "$CONTEXT" ]]; then
    KUBECTL="kubectl --context=$CONTEXT"
fi

echo "=========================================="
echo "INGRESS CLASSES DEBUG"
echo "Context: ${CONTEXT:-current}"
echo "=========================================="

echo ""
echo "--- All Ingress Classes ---"
$KUBECTL get ingressclass -o wide

echo ""
echo "--- Ingress Class Details (YAML) ---"
$KUBECTL get ingressclass -o yaml

echo ""
echo "--- Default Ingress Class ---"
$KUBECTL get ingressclass -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class}{"\n"}{end}'

echo ""
echo "--- Ingress Class Controllers ---"
echo "NAME                          CONTROLLER"
$KUBECTL get ingressclass -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.controller}{"\n"}{end}'
