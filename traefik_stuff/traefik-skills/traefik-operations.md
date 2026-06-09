# traefik - operations

dashboard, metrics, logs, tracing, troubleshooting, scaling, and upgrades for traefik v3.7.x on kubernetes.

---

## the api / dashboard

traefik exposes an internal api on the `traefik` entrypoint (:8080 inside the pod). it serves `/api/*` (json) and `/dashboard/` (ui). **never expose it unauthenticated** — see [traefik-security.md](traefik-security.md).

```bash
# safest access: port-forward, no public exposure
kubectl port-forward -n traefik deploy/traefik 8080:8080

# json api — the source of truth for "did my config get loaded?"
curl -s localhost:8080/api/overview | jq .
curl -s localhost:8080/api/http/routers     | jq '.[] | {name, rule, status, service}'
curl -s localhost:8080/api/http/services    | jq '.[] | {name, status}'
curl -s localhost:8080/api/http/middlewares | jq '.[].name'
curl -s localhost:8080/api/entrypoints      | jq .

# dashboard ui
open http://localhost:8080/dashboard/      # note the trailing slash
```

`status` on a router/service is your first diagnostic: `enabled` = loaded, `disabled` = traefik rejected it (bad rule, missing service, missing middleware). the `error` field says why.

### certificates view (3.7)

3.7 added a **Certificates** menu in the dashboard listing every TLS cert in use, the domains it covers, expiry, and which HTTP/TCP routers attach it. use it to catch expiring certs and "wrong cert served for SNI" issues at a glance.

---

## metrics (prometheus)

```yaml
# helm values
metrics:
  prometheus:
    service: { enabled: true }
    serviceMonitor:
      enabled: true
      metricRelabelings: []
    addEntryPointsLabels: true
    addRoutersLabels: true
    addServicesLabels: true
```

key series:

| metric | meaning |
|--------|---------|
| `traefik_entrypoint_requests_total` | requests per entrypoint, by code/method |
| `traefik_router_requests_total` | requests per router, by code |
| `traefik_service_requests_total` | requests per backend service, by code |
| `traefik_service_request_duration_seconds` | backend latency histogram |
| `traefik_entrypoint_open_connections` | live connections per entrypoint |
| `traefik_config_reloads_total` | config reload count (should be flat unless you change config) |
| `traefik_config_last_reload_success` | 1 if last reload ok |
| `traefik_tls_certs_not_after` | cert expiry epoch — alert on this |

### essential alerts

```yaml
groups:
  - name: traefik
    rules:
      - alert: TraefikHighErrorRate
        expr: |
          sum(rate(traefik_service_requests_total{code=~"5.."}[5m])) by (service)
          / sum(rate(traefik_service_requests_total[5m])) by (service) > 0.05
        for: 5m
        annotations: { summary: "{{ $labels.service }} >5% 5xx" }

      - alert: TraefikConfigReloadFailed
        expr: traefik_config_last_reload_success == 0
        for: 1m
        annotations: { summary: "traefik failed to reload config" }

      - alert: TraefikCertExpiringSoon
        expr: (traefik_tls_certs_not_after - time()) < 7 * 24 * 3600
        for: 1h
        annotations: { summary: "tls cert expiring in <7d" }

      - alert: TraefikHighLatency
        expr: |
          histogram_quantile(0.99,
            sum(rate(traefik_service_request_duration_seconds_bucket[5m])) by (le, service)) > 1
        for: 10m
        annotations: { summary: "{{ $labels.service }} p99 > 1s" }
```

---

## access logs

```yaml
# helm values
logs:
  general: { level: INFO }          # DEBUG only when debugging — very chatty
  access:
    enabled: true
    format: json                    # json for log pipelines
    fields:
      defaultMode: keep
      headers: { defaultMode: drop } # drop by default; keep specific ones if needed
```

json access log line has the fields you need to triage:

```bash
# 5xx and 4xx from the backend (OriginStatus) vs what traefik returned (DownstreamStatus)
kubectl logs -n traefik deploy/traefik | jq -c 'select(.OriginStatus >= 500)
  | {time:.time, host:.RequestHost, path:.RequestPath, origin:.OriginStatus,
     down:.DownstreamStatus, router:.RouterName, svc:.ServiceName, dur:.Duration}'

# which router handled a request (debug routing)
kubectl logs -n traefik deploy/traefik | jq -c 'select(.RequestPath=="/api/version")
  | {router:.RouterName, svc:.ServiceName, code:.DownstreamStatus}'
```

`OriginStatus` = your backend's response. `DownstreamStatus` = what the client got. when they differ, a middleware (errors, retry, redirect) changed it.

---

## tracing

```yaml
tracing:
  otlp:
    enabled: true
    http:
      endpoint: "http://otel-collector.observability:4318/v1/traces"
  sampleRate: 0.1
```

3.7 emits otlp traces per request through the router→middleware→service pipeline, so you can see which middleware added latency.

---

## troubleshooting

### decision tree

```
request fails
├── 404 not found
│   ├── no router matched the Host/Path → check rule, check Host header
│   ├── router status=disabled         → /api/http/routers shows error (bad rule/missing svc)
│   └── ingress not picked up           → wrong ingressClass / provider not enabled
├── 503 service unavailable
│   ├── service has no healthy endpoints → kubectl get endpoints <svc>
│   └── allowEmptyServices + 0 pods       → backend scaled to zero
├── 502 bad gateway
│   ├── backend scheme mismatch (http vs https) → set service scheme / ServersTransport
│   ├── backend closed connection / timeout      → forwardingTimeouts too low
│   └── tls verify to backend failed             → rootCAsSecrets / insecureSkipVerify
├── connection refused / no LB IP
│   └── Service type LoadBalancer pending        → cloud LB / metallb not provisioning
└── tls errors
    ├── wrong cert for host (SNI)  → check Certificates view; cert covers the SNI?
    ├── cert expired               → traefik_tls_certs_not_after / cert-manager renewal
    └── handshake rejected         → TLSOption sniStrict + no matching cert
```

### 404 — the most common, and the nginx-migration-specific causes

```bash
# 1. is the provider seeing your ingress at all?
kubectl logs -n traefik deploy/traefik | grep -iE 'ingress-nginx|kubernetesIngressNGINX' | tail

# 2. did a router actually get built from it?
kubectl port-forward -n traefik deploy/traefik 8080:8080 &
curl -s localhost:8080/api/http/routers | jq '.[] | select(.rule | test("app.example.com"))'

# 3. common migration cause: strictValidatePathType (default true in 3.7)
#    nginx was lenient about pathType; traefik 3.7 validates it strictly.
#    an Ingress with an odd/empty pathType that nginx tolerated may be rejected.
#    fix the Ingress pathType, OR relax:
#      providers.kubernetesIngressNGINX.strictValidatePathType: false

# 4. ingressClass mismatch — provider only owns what its controllerClass matches
kubectl get ingress app -n app-ns -o jsonpath='{.spec.ingressClassName}{"\n"}'
```

### 502 — backend protocol / tls

```bash
# is traefik talking http to an https backend (or vice versa)?
# native: set the service scheme or a ServersTransport.
# check endpoints are real:
kubectl get endpoints app-svc -n app-ns
# test backend directly from a debug pod:
kubectl run dbg --rm -it --image=nicolaka/netshoot -- curl -v http://app-svc.app-ns:80/healthz
```

### "config didn't update"

```bash
# did traefik reload? (should increment when you change config)
curl -s localhost:8080/metrics | grep traefik_config_reloads_total
# did the last reload succeed?
curl -s localhost:8080/metrics | grep traefik_config_last_reload_success   # want 1
# is there a parse error in logs?
kubectl logs -n traefik deploy/traefik | grep -iE 'error|invalid|unable' | tail
```

### middleware ordering bug

middlewares run **in the order listed**. classic mistake: auth after rate-limit, or strip-prefix after a path-based router decision. if a request behaves oddly, dump the chain:

```bash
curl -s localhost:8080/api/http/routers | jq '.[] | select(.name|test("app")) | {rule, middlewares}'
```

### debug pod one-liner

```bash
kubectl run traefik-dbg --rm -it --image=nicolaka/netshoot -n traefik -- bash
# inside: curl the traefik svc, the backend svc, dig hostnames, openssl s_client for tls/sni
```

---

## scaling

traefik is a single Go process; every replica holds the **full** config (no sharding). scale horizontally behind one Service.

```yaml
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 20
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 80 } }
podDisruptionBudget:
  enabled: true
  minAvailable: 2
```

watch: cpu tracks rps + tls handshakes; memory tracks router/middleware count + open connections. if memory climbs with config size, you have a lot of routers — consider consolidating with service-level middlewares (3.7).

caveat: **ACME/letsencrypt** with the default file cert store does **not** scale — each replica would solve challenges independently and store certs locally. use cert-manager (recommended) or a distributed cert store. detail in [traefik-security.md](traefik-security.md).

---

## upgrades

traefik chart `40.x` bundles appVersion `v3.7.x`. upgrade path:

```bash
helm repo update
# review CHANGELOG for breaking static-config changes between chart majors
helm diff upgrade traefik traefik/traefik -n traefik --version 40.2.0 -f values-prod.yaml
helm upgrade traefik traefik/traefik -n traefik --version 40.2.0 -f values-prod.yaml

# rolling update is automatic (Deployment). watch:
kubectl rollout status -n traefik deploy/traefik
curl -s localhost:8080/metrics | grep traefik_config_last_reload_success   # 1
```

CRD upgrades: the chart ships traefik CRDs; bumping chart majors can bump CRD versions. apply CRDs before the controller (argocd sync-wave handles this — see [traefik-helm-argocd.md](traefik-helm-argocd.md)). 3.7.1 specifically added the `CrossProviderNamespaces` option and fixed CVE-2026-44774 — worth being on the patch.

---

## runbooks

### "all routes returning 404 after deploy"

1. `curl /api/overview` — are routers present? if zero, the provider isn't loading config.
2. check provider enabled + `controllerClass` matches your ingressClass.
3. check `strictValidatePathType` (3.7 default true) didn't reject nginx-lenient ingresses.
4. check `traefik_config_last_reload_success` == 1; if 0, grep logs for the parse error.

### "intermittent 502s after nginx cutover"

1. compare `proxy-read-timeout` on the old ingress vs traefik `forwardingTimeouts.responseHeaderTimeout` — traefik default may be shorter.
2. check backend `scheme` (http vs https) — nginx `backend-protocol: HTTPS` maps to a ServersTransport/scheme you may have missed.
3. check the backend isn't closing keep-alives faster than traefik expects.

### "tls cert is wrong / expired"

1. dashboard → Certificates view: does a cert cover the requested SNI? when does it expire?
2. cert-manager managing it? `kubectl get certificate,certificaterequest -A | grep <host>`.
3. `TLSOption.sniStrict: true` + no matching cert = handshake rejected; verify the secret exists in the right namespace.

---

## quick reference

```bash
# health
kubectl get pods -n traefik
kubectl get svc -n traefik traefik
curl -s localhost:8080/ping            # via port-forward; 200 OK = alive

# config introspection
curl -s localhost:8080/api/overview | jq .
curl -s localhost:8080/api/http/routers | jq '.[] | {name,status,rule,service}'

# logs
kubectl logs -n traefik deploy/traefik --tail=100
kubectl logs -n traefik deploy/traefik | jq -c 'select(.OriginStatus>=500)'

# metrics
curl -s localhost:8080/metrics | grep -E 'config_last_reload_success|requests_total|certs_not_after'

# backup
kubectl get ingress,ingressroute,middleware,traefikservice,tlsoption,serverstransport -A -o yaml > traefik-backup.yaml
```

---

## references

- api & dashboard: https://doc.traefik.io/traefik/operations/api/ and /dashboard/
- prometheus metrics: https://doc.traefik.io/traefik/observability/metrics/prometheus/
- access logs: https://doc.traefik.io/traefik/observability/access-logs/
- tracing: https://doc.traefik.io/traefik/observability/tracing/overview/
