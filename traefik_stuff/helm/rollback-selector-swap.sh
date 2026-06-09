#!/usr/bin/env bash
# STRATEGY A rollback: patch the ingress-nginx-controller Service selector + ports back to nginx.
# nginx pods are still running, so traffic flips straight back. Azure IP + DNS never moved.
#
# IMPORTANT: edit the SELECTOR and PORTS below to match what your phase-0 backup captured
# (02-nginx-svc-backup.yaml -> .spec.selector and .spec.ports). The values here are the
# stock ingress-nginx helm-chart defaults; YOUR cluster may differ.
set -euo pipefail

NS="${NS:-ingress-nginx}"
SVC="${SVC:-ingress-nginx-controller}"

echo "rolling Service '$SVC' back to nginx pods..."
kubectl patch svc "$SVC" -n "$NS" --type=merge -p '{
  "spec": {
    "selector": {
      "app.kubernetes.io/name": "ingress-nginx",
      "app.kubernetes.io/instance": "ingress-nginx",
      "app.kubernetes.io/component": "controller"
    },
    "ports": [
      { "name": "http",  "port": 80,  "protocol": "TCP", "targetPort": "http"  },
      { "name": "https", "port": 443, "protocol": "TCP", "targetPort": "https" }
    ]
  }
}'

echo "== endpoints (should be nginx pod IPs again) =="
kubectl get endpointslice -n "$NS" -l "kubernetes.io/service-name=$SVC" -o wide
kubectl get svc -n "$NS" "$SVC" -o wide
