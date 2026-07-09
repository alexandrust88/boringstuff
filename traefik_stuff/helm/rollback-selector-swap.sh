#!/usr/bin/env bash
# Rollback: REPLACE the ingress-nginx-controller Service selector + ports back to nginx.
# Works for both the instant selector swap AND the shared-Service canary (it restores the
# original nginx-only selector). nginx pods must still be running (scale up first if at 0):
#   kubectl scale deploy ingress-nginx-controller -n ingress-nginx --replicas=2
#
# IMPORTANT: uses a json REPLACE op — a merge/strategic patch would MERGE selector maps,
# leaving traefik labels behind and producing a selector that matches nothing.
#
# IMPORTANT: edit the SELECTOR and PORTS below to match what your phase-0 backup captured
# (00-nginx-svc.yaml -> .spec.selector and .spec.ports). The values here are the stock
# ingress-nginx helm-chart defaults; YOUR cluster may differ.
set -euo pipefail

NS="${NS:-ingress-nginx}"
SVC="${SVC:-ingress-nginx-controller}"

echo "rolling Service '$SVC' back to nginx pods..."
kubectl patch svc "$SVC" -n "$NS" --type=json -p='[
  {"op":"replace","path":"/spec/selector","value":{
    "app.kubernetes.io/name":"ingress-nginx",
    "app.kubernetes.io/instance":"ingress-nginx",
    "app.kubernetes.io/component":"controller"}},
  {"op":"replace","path":"/spec/ports","value":[
    {"name":"http","port":80,"protocol":"TCP","targetPort":"http"},
    {"name":"https","port":443,"protocol":"TCP","targetPort":"https"}]}
]'

echo "== endpoints (should be nginx pod IPs again) =="
kubectl get endpointslice -n "$NS" -l "kubernetes.io/service-name=$SVC" -o wide
kubectl get svc -n "$NS" "$SVC" -o wide
