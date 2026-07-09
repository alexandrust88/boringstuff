#!/usr/bin/env bash
# STRATEGY "instant selector swap" cutover: repoint the EXISTING ingress-nginx-controller
# Service at traefik pods. same Service object -> same Azure LB -> same public IP -> DNS untouched.
# only spec.selector + spec.ports[].targetPort change. port 80/443 stay (LB frontend unchanged).
#
# NOTE: for ZERO-downtime gradual migration prefer the shared-Service canary instead
# (values-azure-shared-service.yaml + traefik-nginx-migration-azure-zero-downtime.md).
#
# IMPORTANT: the selector is REPLACED with a json patch op. a merge/strategic patch would
# MERGE the maps, leaving the old nginx labels in the selector -> matches nothing -> outage.
#
# PRE-REQS:
#   - traefik installed in the ingress-nginx namespace (values-azure-selector-swap.yaml), pods Ready
#   - validated via port-forward
#   - gitops frozen on this Service (ignoreDifferences on /spec/selector + /spec/ports), or Service detached
set -euo pipefail

NS="${NS:-ingress-nginx}"
SVC="${SVC:-ingress-nginx-controller}"
# match the labels your traefik pods actually have: kubectl get pods -n $NS -l app.kubernetes.io/name=traefik --show-labels
TRAEFIK_NAME="${TRAEFIK_NAME:-traefik}"
TRAEFIK_INSTANCE="${TRAEFIK_INSTANCE:-traefik}"

echo "== before =="
kubectl get svc -n "$NS" "$SVC" -o wide
echo "current selector:"; kubectl get svc -n "$NS" "$SVC" -o jsonpath='{.spec.selector}{"\n"}'

echo "== traefik pods that will become the backend =="
kubectl get pods -n "$NS" -l "app.kubernetes.io/name=$TRAEFIK_NAME,app.kubernetes.io/instance=$TRAEFIK_INSTANCE" -o wide

read -r -p "REPLACE Service selector -> traefik, targetPort 80->8000 443->8443 ? [y/N] " ok
[ "$ok" = "y" ] || { echo "aborted"; exit 1; }

kubectl patch svc "$SVC" -n "$NS" --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/spec/selector\",\"value\":{
    \"app.kubernetes.io/name\":\"$TRAEFIK_NAME\",
    \"app.kubernetes.io/instance\":\"$TRAEFIK_INSTANCE\"}},
  {\"op\":\"replace\",\"path\":\"/spec/ports\",\"value\":[
    {\"name\":\"http\",\"port\":80,\"protocol\":\"TCP\",\"targetPort\":8000},
    {\"name\":\"https\",\"port\":443,\"protocol\":\"TCP\",\"targetPort\":8443}]}
]"

echo "== after: endpoints should now be traefik pod IPs =="
kubectl get endpointslice -n "$NS" -l "kubernetes.io/service-name=$SVC" -o wide
echo "== Service (EXTERNAL-IP must be unchanged) =="
kubectl get svc -n "$NS" "$SVC" -o wide
echo
echo "now flip publishService -> true:"
echo "  helm upgrade traefik traefik/traefik -n $NS --version 40.1.0 -f values-azure-selector-swap.yaml \\"
echo "    --set providers.kubernetesIngressNGINX.publishService.enabled=true"
