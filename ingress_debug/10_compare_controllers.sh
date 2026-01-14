#!/bin/bash
# Compare Two Ingress Controllers
# Usage: ./10_compare_controllers.sh [context]

set -euo pipefail

CONTEXT="${1:-}"
KUBECTL="kubectl"

if [[ -n "$CONTEXT" ]]; then
    KUBECTL="kubectl --context=$CONTEXT"
fi

echo "=========================================="
echo "INGRESS CONTROLLER COMPARISON"
echo "Context: ${CONTEXT:-current}"
echo "=========================================="

echo ""
echo "--- Ingress Classes Side by Side ---"
echo ""
printf "%-30s %-50s %-10s\n" "CLASS NAME" "CONTROLLER" "DEFAULT"
printf "%-30s %-50s %-10s\n" "----------" "----------" "-------"
$KUBECTL get ingressclass -o json | jq -r '.items[] | "\(.metadata.name)\t\(.spec.controller)\t\(.metadata.annotations["ingressclass.kubernetes.io/is-default-class"] // "false")"' 2>/dev/null | while IFS=$'\t' read -r name controller default; do
    printf "%-30s %-50s %-10s\n" "$name" "$controller" "$default"
done

echo ""
echo "--- Controller Deployments Comparison ---"
echo ""
for deploy in $($KUBECTL get deploy --all-namespaces -o name 2>/dev/null | xargs -I{} sh -c "$KUBECTL get {} --all-namespaces -o jsonpath='{.metadata.namespace}/{.metadata.name} ' 2>/dev/null" | tr ' ' '\n' | grep -iE "(nginx|ingress)" || true); do
    NS=$(echo "$deploy" | cut -d/ -f1)
    NAME=$(echo "$deploy" | cut -d/ -f2)

    echo "=== $NS/$NAME ==="

    # Get the ingress class this controller watches
    WATCHED_CLASS=$($KUBECTL get deploy "$NAME" -n "$NS" -o yaml 2>/dev/null | grep -oE "(--ingress-class=|--controller-class=)[^ ]*" | cut -d= -f2 || echo "default/all")
    echo "Watches Class: ${WATCHED_CLASS:-default/all}"

    # Get replica count
    REPLICAS=$($KUBECTL get deploy "$NAME" -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    echo "Replicas: $REPLICAS"

    # Get the associated service
    SVC=$($KUBECTL get svc -n "$NS" -o name 2>/dev/null | grep -iE "(nginx|ingress)" | head -1 || echo "unknown")
    EXTERNAL_IP=$($KUBECTL get svc -n "$NS" -o json 2>/dev/null | jq -r ".items[] | select(.metadata.name | test(\"nginx|ingress\"; \"i\")) | .status.loadBalancer.ingress[0].ip // .status.loadBalancer.ingress[0].hostname // \"pending\"" | head -1 2>/dev/null || echo "unknown")
    echo "Service: $SVC"
    echo "External IP: $EXTERNAL_IP"
    echo ""
done

echo ""
echo "--- Which Ingresses Use Which Class ---"
echo ""
for class in $($KUBECTL get ingressclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo "Class: $class"
    echo "  Ingresses using spec.ingressClassName=$class:"
    $KUBECTL get ingress --all-namespaces -o json 2>/dev/null | jq -r ".items[] | select(.spec.ingressClassName == \"$class\") | \"    \(.metadata.namespace)/\(.metadata.name)\"" 2>/dev/null || echo "    (none or jq error)"

    echo "  Ingresses using annotation kubernetes.io/ingress.class=$class:"
    $KUBECTL get ingress --all-namespaces -o json 2>/dev/null | jq -r ".items[] | select(.metadata.annotations[\"kubernetes.io/ingress.class\"] == \"$class\") | \"    \(.metadata.namespace)/\(.metadata.name)\"" 2>/dev/null || echo "    (none or jq error)"
    echo ""
done

echo ""
echo "--- Potential Issues ---"
echo ""

# Check for ingresses without class
NO_CLASS=$($KUBECTL get ingress --all-namespaces -o json 2>/dev/null | jq -r '.items[] | select(.spec.ingressClassName == null and .metadata.annotations["kubernetes.io/ingress.class"] == null) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null)
if [[ -n "$NO_CLASS" ]]; then
    echo "WARNING: Ingresses without explicit class (will use default):"
    echo "$NO_CLASS"
else
    echo "OK: All ingresses have explicit class"
fi

# Check for multiple default classes
DEFAULT_COUNT=$($KUBECTL get ingressclass -o json 2>/dev/null | jq '[.items[] | select(.metadata.annotations["ingressclass.kubernetes.io/is-default-class"] == "true")] | length' 2>/dev/null)
if [[ "$DEFAULT_COUNT" -gt 1 ]]; then
    echo ""
    echo "WARNING: Multiple default ingress classes found!"
    $KUBECTL get ingressclass -o json | jq -r '.items[] | select(.metadata.annotations["ingressclass.kubernetes.io/is-default-class"] == "true") | .metadata.name' 2>/dev/null
fi
