#!/bin/bash
# Analyze and Suggest Fixes
# Usage: ./11_fix_suggestions.sh <ingress-namespace> <ingress-name> [context]

set -euo pipefail

NAMESPACE="${1:-}"
INGRESS_NAME="${2:-}"
CONTEXT="${3:-}"
KUBECTL="kubectl"

if [[ -z "$NAMESPACE" ]] || [[ -z "$INGRESS_NAME" ]]; then
    echo "Usage: $0 <namespace> <ingress-name> [context]"
    echo "Example: $0 argocd argocd-server my-cluster"
    exit 1
fi

if [[ -n "$CONTEXT" ]]; then
    KUBECTL="kubectl --context=$CONTEXT"
fi

echo "=========================================="
echo "INGRESS FIX SUGGESTIONS"
echo "Ingress: $NAMESPACE/$INGRESS_NAME"
echo "Context: ${CONTEXT:-current}"
echo "=========================================="

# Get ingress details
INGRESS_CLASS=$($KUBECTL get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)
INGRESS_ANNOTATION=$($KUBECTL get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.kubernetes\.io/ingress\.class}' 2>/dev/null)
INGRESS_HOST=$($KUBECTL get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null)

echo ""
echo "Current Configuration:"
echo "  spec.ingressClassName: ${INGRESS_CLASS:-<not set>}"
echo "  annotation: ${INGRESS_ANNOTATION:-<not set>}"
echo "  host: ${INGRESS_HOST:-<not set>}"

echo ""
echo "Available Ingress Classes:"
$KUBECTL get ingressclass -o custom-columns=NAME:.metadata.name,CONTROLLER:.spec.controller,DEFAULT:.metadata.annotations."ingressclass\.kubernetes\.io/is-default-class"

echo ""
echo "=========================================="
echo "DIAGNOSIS"
echo "=========================================="

# Problem 1: No class specified
if [[ -z "$INGRESS_CLASS" ]] && [[ -z "$INGRESS_ANNOTATION" ]]; then
    echo ""
    echo "PROBLEM: No ingress class specified!"
    echo "  The ingress will be handled by the default class controller."
    echo ""
    echo "FIX: Add spec.ingressClassName to your ingress:"
    echo ""
    echo "  kubectl patch ingress $INGRESS_NAME -n $NAMESPACE --type=json \\"
    echo "    -p='[{\"op\": \"add\", \"path\": \"/spec/ingressClassName\", \"value\": \"YOUR-CLASS-NAME\"}]'"
fi

# Problem 2: Using deprecated annotation
if [[ -n "$INGRESS_ANNOTATION" ]] && [[ -z "$INGRESS_CLASS" ]]; then
    echo ""
    echo "PROBLEM: Using deprecated annotation instead of spec.ingressClassName"
    echo "  Some controllers may not respect the annotation."
    echo ""
    echo "FIX: Switch to spec.ingressClassName:"
    echo ""
    echo "  kubectl patch ingress $INGRESS_NAME -n $NAMESPACE --type=json \\"
    echo "    -p='[{\"op\": \"add\", \"path\": \"/spec/ingressClassName\", \"value\": \"$INGRESS_ANNOTATION\"}]'"
fi

# Problem 3: Class doesn't exist
if [[ -n "$INGRESS_CLASS" ]]; then
    CLASS_EXISTS=$($KUBECTL get ingressclass "$INGRESS_CLASS" 2>/dev/null && echo "yes" || echo "no")
    if [[ "$CLASS_EXISTS" == "no" ]]; then
        echo ""
        echo "PROBLEM: Ingress class '$INGRESS_CLASS' does not exist!"
        echo ""
        echo "FIX: Create the ingress class or change to an existing one:"
        echo ""
        echo "  Available classes:"
        $KUBECTL get ingressclass -o name | sed 's/ingressclass.networking.k8s.io\//    /'
    fi
fi

# Check DNS
if [[ -n "$INGRESS_HOST" ]]; then
    echo ""
    echo "=========================================="
    echo "DNS CHECK"
    echo "=========================================="

    RESOLVED_IP=$(dig +short "$INGRESS_HOST" 2>/dev/null | head -1)
    echo "Host: $INGRESS_HOST"
    echo "Resolves to: ${RESOLVED_IP:-<not resolved>}"

    # Get expected IPs from controllers
    echo ""
    echo "Controller External IPs:"
    $KUBECTL get svc --all-namespaces -o json 2>/dev/null | jq -r '.items[] | select(.spec.type=="LoadBalancer") | select(.metadata.name | test("nginx|ingress"; "i")) | "  \(.metadata.name): \(.status.loadBalancer.ingress[0].ip // .status.loadBalancer.ingress[0].hostname // "pending")"' 2>/dev/null || echo "  Could not retrieve"

    echo ""
    echo "If DNS points to wrong controller, update your DNS record to point to the correct IP."
fi

echo ""
echo "=========================================="
echo "QUICK FIX COMMANDS"
echo "=========================================="

echo ""
echo "# List available classes:"
echo "kubectl ${CONTEXT:+--context=$CONTEXT }get ingressclass"

echo ""
echo "# Set ingress class (replace YOUR-CLASS):"
echo "kubectl ${CONTEXT:+--context=$CONTEXT }patch ingress $INGRESS_NAME -n $NAMESPACE --type=merge -p '{\"spec\":{\"ingressClassName\":\"YOUR-CLASS\"}}'"

echo ""
echo "# View ingress:"
echo "kubectl ${CONTEXT:+--context=$CONTEXT }get ingress $INGRESS_NAME -n $NAMESPACE -o yaml"

echo ""
echo "# Force controller to re-sync:"
echo "kubectl ${CONTEXT:+--context=$CONTEXT }annotate ingress $INGRESS_NAME -n $NAMESPACE debug-timestamp=\"\$(date +%s)\" --overwrite"
