#!/bin/bash
# Specific Ingress Deep Dive
# Usage: ./05_specific_ingress.sh <namespace> <ingress-name> [context]

set -euo pipefail

NAMESPACE="${1:-}"
INGRESS_NAME="${2:-}"
CONTEXT="${3:-}"
KUBECTL="kubectl"

if [[ -z "$NAMESPACE" ]] || [[ -z "$INGRESS_NAME" ]]; then
    echo "Usage: $0 <namespace> <ingress-name> [context]"
    echo "Example: $0 argocd argocd-server-ingress my-cluster"
    exit 1
fi

if [[ -n "$CONTEXT" ]]; then
    KUBECTL="kubectl --context=$CONTEXT"
fi

echo "=========================================="
echo "SPECIFIC INGRESS DEBUG"
echo "Ingress: $NAMESPACE/$INGRESS_NAME"
echo "Context: ${CONTEXT:-current}"
echo "=========================================="

echo ""
echo "--- Ingress YAML ---"
$KUBECTL get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o yaml

echo ""
echo "--- Ingress Describe ---"
$KUBECTL describe ingress "$INGRESS_NAME" -n "$NAMESPACE"

echo ""
echo "--- Ingress Class Specified ---"
INGRESS_CLASS=$($KUBECTL get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.ingressClassName}')
INGRESS_CLASS_ANNOTATION=$($KUBECTL get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.kubernetes\.io/ingress\.class}')
echo "spec.ingressClassName: ${INGRESS_CLASS:-<not set>}"
echo "annotation kubernetes.io/ingress.class: ${INGRESS_CLASS_ANNOTATION:-<not set>}"

echo ""
echo "--- Backend Service Check ---"
for rule in $($KUBECTL get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.rules[*].http.paths[*].backend.service.name}'); do
    echo ""
    echo "Service: $rule"
    $KUBECTL get svc "$rule" -n "$NAMESPACE" -o wide 2>/dev/null || echo "Service not found!"
    $KUBECTL get endpoints "$rule" -n "$NAMESPACE" 2>/dev/null || echo "Endpoints not found!"
done

echo ""
echo "--- Events related to ingress ---"
$KUBECTL get events -n "$NAMESPACE" --field-selector involvedObject.name="$INGRESS_NAME" --sort-by='.lastTimestamp' 2>/dev/null || true
