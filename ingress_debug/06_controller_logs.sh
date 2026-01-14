#!/bin/bash
# Controller Logs Debugging
# Usage: ./06_controller_logs.sh [context] [lines]

set -euo pipefail

CONTEXT="${1:-}"
LINES="${2:-100}"
KUBECTL="kubectl"

if [[ -n "$CONTEXT" ]]; then
    KUBECTL="kubectl --context=$CONTEXT"
fi

echo "=========================================="
echo "INGRESS CONTROLLER LOGS"
echo "Context: ${CONTEXT:-current}"
echo "Lines: $LINES"
echo "=========================================="

echo ""
echo "--- Finding controller pods ---"
CONTROLLER_PODS=$($KUBECTL get pods --all-namespaces -o wide | grep -iE "(nginx|ingress)" | grep -i controller || true)
echo "$CONTROLLER_PODS"

if [[ -z "$CONTROLLER_PODS" ]]; then
    echo "No controller pods found"
    exit 0
fi

echo ""
echo "--- Controller Logs ---"
while IFS= read -r line; do
    NS=$(echo "$line" | awk '{print $1}')
    POD=$(echo "$line" | awk '{print $2}')
    if [[ -n "$NS" ]] && [[ -n "$POD" ]]; then
        echo ""
        echo "=== $NS/$POD ==="
        $KUBECTL logs "$POD" -n "$NS" --tail="$LINES" 2>/dev/null || echo "Could not get logs"
    fi
done <<< "$CONTROLLER_PODS"
