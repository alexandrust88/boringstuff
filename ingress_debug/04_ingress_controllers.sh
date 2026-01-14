#!/bin/bash
# Ingress Controllers Debugging
# Usage: ./04_ingress_controllers.sh [context]

set -euo pipefail

CONTEXT="${1:-}"
KUBECTL="kubectl"

if [[ -n "$CONTEXT" ]]; then
    KUBECTL="kubectl --context=$CONTEXT"
fi

echo "=========================================="
echo "INGRESS CONTROLLERS DEBUG"
echo "Context: ${CONTEXT:-current}"
echo "=========================================="

echo ""
echo "--- Looking for NGINX Ingress Controllers ---"
echo ""
echo "Deployments:"
$KUBECTL get deploy --all-namespaces -o wide | grep -iE "(nginx|ingress)" || echo "None found"

echo ""
echo "DaemonSets:"
$KUBECTL get ds --all-namespaces -o wide | grep -iE "(nginx|ingress)" || echo "None found"

echo ""
echo "--- Controller Pods ---"
$KUBECTL get pods --all-namespaces -o wide | grep -iE "(nginx|ingress)" || echo "None found"

echo ""
echo "--- Controller Services (LoadBalancer/NodePort) ---"
$KUBECTL get svc --all-namespaces -o wide | grep -iE "(nginx|ingress)" || echo "None found"

echo ""
echo "--- Controller ConfigMaps ---"
$KUBECTL get cm --all-namespaces | grep -iE "(nginx|ingress)" || echo "None found"

echo ""
echo "--- Controller Arguments (from deployments) ---"
for ns in $($KUBECTL get ns -o name | cut -d/ -f2); do
    for deploy in $($KUBECTL get deploy -n "$ns" -o name 2>/dev/null | grep -iE "(nginx|ingress)" || true); do
        if [[ -n "$deploy" ]]; then
            echo ""
            echo "=== $ns / $deploy ==="
            $KUBECTL get "$deploy" -n "$ns" -o jsonpath='{.spec.template.spec.containers[*].args}' | tr ',' '\n' || true
        fi
    done
done

echo ""
echo "--- Controller Class Watched (from args) ---"
for ns in $($KUBECTL get ns -o name | cut -d/ -f2); do
    for deploy in $($KUBECTL get deploy -n "$ns" -o name 2>/dev/null | grep -iE "(nginx|ingress)" || true); do
        if [[ -n "$deploy" ]]; then
            echo ""
            echo "=== $ns / $deploy ==="
            $KUBECTL get "$deploy" -n "$ns" -o yaml | grep -E "(ingress-class|controller-class|watch-ingress-without-class)" || echo "No class args found"
        fi
    done
done
