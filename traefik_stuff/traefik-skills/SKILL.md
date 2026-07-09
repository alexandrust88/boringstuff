# traefik skill

comprehensive skill for deploying, configuring, operating, and troubleshooting traefik proxy on kubernetes as a drop-in replacement for ingress-nginx.

target versions:

- **traefik proxy v3.7.1** (codename "langres", released 2026-05-06; v3.7.1 patch adds `CrossProviderNamespaces` + fixes CVE-2026-44774)
- **traefik helm chart 40.1.0 / 40.2.0** (these bundle appVersion `v3.7.1`; chart `40.0.0` bundled `v3.7.0`)

> version-naming note: the chart series is `40.x`, **not** `0.40.0`. there is no chart `0.40.0` that ships v3.7.1. if a pin says `0.40.0` it is wrong — use `40.1.0` or later. the kubernetesIngressNGINX provider requires traefik **v3.6.2 or later**; v3.7.x is where it graduates out of experimental.

---

## overview

traefik v3.7 is the release that makes traefik a genuine **drop-in replacement for ingress-nginx**. the new `kubernetesIngressNGINX` provider reads your existing `networking.k8s.io/v1` `Ingress` objects (the ones with `ingressClassName: nginx` and `nginx.ingress.kubernetes.io/*` annotations) and translates 85+ of the most common annotations natively — covering >90% of real-world usage — with **no yaml rewrite, no annotation conversion, no big-bang cutover**.

that means migration is not "rewrite every ingress into a new CRD". it is "deploy traefik, point it at the same `nginx` ingressClass, run both controllers in parallel, shift dns, delete nginx". the CRD-native model (`IngressRoute`, `Middleware`, `TraefikService`) is available for new work and for things nginx annotations could never express cleanly — but it is optional for migration.

**source repo**: `./`

## when to use this skill

- deploying traefik on kubernetes as an ingress controller
- replacing ingress-nginx with traefik with zero ingress-manifest changes
- enabling and tuning the `kubernetesIngressNGINX` compatibility provider
- mapping `nginx.ingress.kubernetes.io/*` annotations to traefik behavior
- running ingress-nginx and traefik side-by-side during a phased cutover
- authoring native traefik CRDs: `IngressRoute`, `Middleware`, `TraefikService`, `ServersTransport`, `TLSOption`
- configuring tls termination, http→https redirect, cert-manager integration
- setting up the dashboard, metrics, access logs, tracing
- gitops deployment with argocd (helm + sync waves)
- troubleshooting 404/502/503, tls/sni, middleware ordering, provider conflicts

## the three deployment shapes

pick based on where you are in the migration:

| shape | provider(s) enabled | use when |
|-------|---------------------|----------|
| **compat / migration** | `kubernetesIngressNGINX` (+ keep nginx running) | replacing ingress-nginx; reuse existing `Ingress` objects unchanged |
| **native CRD** | `kubernetesCRD` (+ `kubernetesIngress`) | greenfield, or once migrated and you want `Middleware`/`IngressRoute` |
| **gateway api** | `kubernetesGateway` | standardizing on gateway api (v1.5 supported in 3.7); coexists with envoy gateway-style model |

most real migrations run **compat** first, validate, cut dns, decommission nginx, then *optionally* refactor hot paths into native CRDs over time. you do not have to.

---

## architecture

### single-process data+control plane

unlike envoy gateway (separate controller + per-gateway envoy fleets), traefik is **one process** that is both the config-watcher and the proxy:

```
traefik pod (Deployment, 2+ replicas)
  providers (config sources, watched continuously, hot-reloaded):
    kubernetesIngressNGINX  -> reads Ingress (ingressClassName: nginx) + nginx annotations
    kubernetesCRD           -> reads IngressRoute / Middleware / TraefikService / TLSOption
    kubernetesIngress       -> reads vanilla Ingress (non-nginx)
    kubernetesGateway       -> reads Gateway / HTTPRoute (gateway api v1.5)
  entryPoints (listeners):
    web       :8000 -> exposedPort 80
    websecure :8443 -> exposedPort 443 (tls)
    traefik   :8080 -> internal api/dashboard/ping/metrics
  routers -> middlewares -> services -> backend pods
  Service type LoadBalancer (one external IP for the whole controller)
```

there is **no per-host proxy fleet** and **no xDS**. config changes are applied in-process on watch events. HA = run N replicas behind one Service; each replica holds the full config. for ACME/letsencrypt HA you need a shared cert store (see security doc) because the default file store is per-pod.

### request pipeline (the mental model that matters)

```
entryPoint (web/websecure)
  -> router        (rule: Host(`x`) && PathPrefix(`/y`), priority, tls)
     -> middleware chain  (ordered! redirect -> auth -> ratelimit -> headers -> ...)
        -> service          (load-balanced backend, optional sticky/healthcheck)
           -> backend pods
```

every nginx annotation lands somewhere in this pipeline. the compat provider builds the router + the middleware chain + the service for you from the `Ingress` object. when you go native, **you** assemble them.

### how the compat provider maps concepts

```
Ingress object (ingressClassName: nginx)
  spec.rules[].host                       -> router rule Host(`...`)
  spec.rules[].http.paths[].path          -> router rule PathPrefix(`...`) / Path(`...`)
  spec.tls[]                              -> router tls + cert from referenced Secret
  annotation: ssl-redirect / force-ssl    -> redirect-to-https middleware on :80 router
  annotation: rewrite-target              -> replacePathRegex / stripPrefix middleware
  annotation: auth-type/auth-secret       -> basicAuth/digestAuth middleware
  annotation: limit-rps/rpm/connections   -> rateLimit / inFlightReq middleware
  annotation: canary*                     -> weighted service split
  annotation: cors-*                      -> headers middleware
  annotation: whitelist-source-range      -> ipAllowList middleware
  annotation: proxy-*-timeout / body-size -> serversTransport + buffering settings
```

full mapping table lives in [traefik-nginx-migration.md](traefik-nginx-migration.md).

### native CRD hierarchy (for post-migration / greenfield)

```
IngressRoute (namespace-scoped)
  entryPoints: [web, websecure]
  routes:
    - match: Host(`app.example.com`) && PathPrefix(`/api`)
      priority: 100
      middlewares: [ <Middleware refs, ordered> ]
      services:
        - name: app-svc        (k8s Service, or a TraefikService for advanced)
          port: 80
  tls:
    secretName: app-tls        (or certResolver: le for ACME)

Middleware (namespace-scoped, reusable)
  one of: redirectScheme, stripPrefix, replacePathRegex, headers, basicAuth,
          rateLimit, inFlightReq, ipAllowList, circuitBreaker, retry, ...

TraefikService (namespace-scoped)
  weighted:   N services with weights (canary / blue-green)
  mirroring:  shadow traffic to a second service
  failover:   primary + fallback, switch on error status (new in 3.7)
```

---

## what's new in 3.7 you actually use

| feature | why it matters for nginx replacement |
|---------|--------------------------------------|
| **kubernetesIngressNGINX provider GA** | the whole point: reuse `Ingress` + 85+ nginx annotations, no rewrite |
| **service-level middlewares** | attach middleware on the `Service`, not just the router — dedup when many routers hit one backend; powers gateway-api filters on backends |
| **retry / failover by HTTP status code** | `retry.retryOn.statusCodes`, `TraefikService.failover.errors.status` — nginx `proxy-next-upstream` equivalent, done right |
| **dashboard certificates view** | see every TLS cert, domains, expiry, and which routers use it (HTTP + TCP) |
| **gateway api v1.5** | multiple `certificateRefs` per listener (SNI), `BackendTLSPolicy.caCertificateRefs` from Secret |
| **snippet allowlisting** | nginx `*-snippet` annotations are parsed into a curated safe allowlist (header manip, rewrites, client-IP/URI interpolation), not executed raw |

---

## quickstart: traefik as nginx replacement (compat mode)

```bash
# 1. add chart repo
helm repo add traefik https://traefik.github.io/charts
helm repo update

# 2. install traefik 40.1.0+ with the nginx-compat provider on, status-publish OFF
#    (status-publish off avoids fighting nginx over Ingress .status during coexistence)
cat > traefik-compat-values.yaml <<'EOF'
deployment:
  replicas: 2
providers:
  kubernetesIngressNGINX:
    enabled: true
    publishService:
      enabled: false          # IMPORTANT during coexistence with ingress-nginx
  kubernetesCRD:
    enabled: true             # so you can add native Middleware/IngressRoute later
  kubernetesIngress:
    enabled: false            # avoid double-owning vanilla Ingress; nginx provider handles nginx class
ingressClass:
  enabled: true
  isDefaultClass: false       # don't steal default while nginx is still live
service:
  spec:
    type: LoadBalancer
ports:
  web:
    redirectTo:               # global http->https if you want it; or per-ingress via annotations
      port: websecure
EOF

helm upgrade --install traefik traefik/traefik \
  -n traefik --create-namespace \
  --version 40.1.0 \
  -f traefik-compat-values.yaml

# 3. confirm traefik picked up your existing nginx ingresses
kubectl logs -n traefik deploy/traefik | grep -i ingress-nginx
kubectl get svc -n traefik traefik   # note EXTERNAL-IP

# 4. test an existing host against traefik's IP WITHOUT touching dns
TRAEFIK_IP=$(kubectl get svc -n traefik traefik \
  -o go-template='{{ (index .status.loadBalancer.ingress 0).ip }}')
curl -v --resolve app.example.com:443:$TRAEFIK_IP https://app.example.com/
```

nothing about your `Ingress` objects changed. nginx is still serving the real dns. you are A/B testing traefik against the same manifests. cutover = dns. detail in [traefik-nginx-migration.md](traefik-nginx-migration.md).

---

## helm chart patterns

### wrapper chart (recommended for multi-cluster gitops)

```yaml
# Chart.yaml
apiVersion: v2
name: traefik-wrapper
version: 1.0.0
dependencies:
  - name: traefik
    version: "40.1.0"               # bundles appVersion v3.7.1
    repository: "https://traefik.github.io/charts"
```

### key values.yaml structure

```yaml
traefik:
  deployment:
    replicas: 2                      # HA; each replica holds full config
  providers:
    kubernetesIngressNGINX:
      enabled: true                  # nginx-compat
      controllerClass: "k8s.io/ingress-nginx"
      publishService: { enabled: false }   # during coexistence
    kubernetesCRD:   { enabled: true }
    kubernetesGateway: { enabled: false }
  ingressClass:
    enabled: true
    isDefaultClass: false            # flip to true only after nginx is gone
  service:
    spec: { type: LoadBalancer }
  ports:
    web:      { exposedPort: 80 }
    websecure:{ exposedPort: 443, http: { tls: { enabled: true } } }
  ingressRoute:
    dashboard: { enabled: false }    # enable behind auth only (see security doc)
  metrics:
    prometheus:
      service: { enabled: true }
      serviceMonitor: { enabled: true }
  logs:
    access: { enabled: true }
  resources:
    requests: { cpu: 200m, memory: 256Mi }
    limits:   { cpu: 1000m, memory: 1Gi }
```

### production overlay (values-prod.yaml)

```yaml
traefik:
  deployment:
    replicas: 3
    podAnnotations:
      prometheus.io/scrape: "true"
      prometheus.io/port: "9100"
  podDisruptionBudget:
    enabled: true
    minAvailable: 2
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels: { app.kubernetes.io/name: traefik }
          topologyKey: kubernetes.io/hostname
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels: { app.kubernetes.io/name: traefik }
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 20
    metrics:
      - type: Resource
        resource: { name: cpu, target: { type: Utilization, averageUtilization: 80 } }
  resources:
    requests: { cpu: 500m, memory: 512Mi }
    limits:   { cpu: 2000m, memory: 2Gi }
  podSecurityContext: { runAsNonRoot: true, runAsUser: 65532 }
```

---

## resource sizing guide

| traffic level | traefik cpu request | memory request | replicas |
|---------------|---------------------|----------------|----------|
| low (<1k rps) | 100m | 128Mi | 2 |
| medium (1-5k rps) | 250m | 256Mi | 3 |
| high (5-20k rps) | 500m | 512Mi | 5 |
| very high (>20k rps) | 1000m | 1Gi | 10+ |

traefik is a single Go process; cpu scales with rps + tls handshakes, memory with number of routers/middlewares/connections. it is typically lighter than an equivalent envoy fleet for the same routing surface.

---

## argocd gitops deployment

### app-of-apps with sync waves

```
sync-wave 0: traefik helm release (controller + CRDs + ingressClass)
sync-wave 1: TLSOption / default Middleware (cluster-wide)
sync-wave 2: IngressRoute / app routes  (or just leave existing nginx Ingress in place)
```

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  source:
    repoURL: https://traefik.github.io/charts
    chart: traefik
    targetRevision: 40.1.0
    helm:
      valueFiles: [ values-prod.yaml ]
  destination:
    namespace: traefik
```

### dependency ordering (critical)

```
CRDs (installed by chart) must exist before IngressRoute/Middleware
IngressClass must exist before Ingress objects resolve to traefik
TLS Secret must exist before a router references it
Middleware must exist before an IngressRoute references it (cross-namespace needs allowCrossNamespace)
```

detail: [traefik-helm-argocd.md](traefik-helm-argocd.md).

---

## sub-documents

| document | content |
|----------|---------|
| [traefik-nginx-migration.md](traefik-nginx-migration.md) | **the core doc** — kubernetesIngressNGINX provider, full annotation mapping, coexistence, status-race fix, dns cutover, rollback, nginx decommission, migration tool |
| [traefik-nginx-migration-azure-zero-downtime.md](traefik-nginx-migration-azure-zero-downtime.md) | **azure aks v2 (preferred): ZERO downtime, same ip, no dns change** — nginx + traefik behind the SAME Service via named targetPorts; gradual canary by scaling nginx down; full worked example; verified against chart 40.1.0 renders + v3.7.1 source |
| [traefik-nginx-migration-azure-ip-reuse.md](traefik-nginx-migration-azure-ip-reuse.md) | azure aks v1 — instant selector swap (superseded by v2) + **strategy B: move the static ip** (required when traefik must live in its own namespace; ~1-5 min gap) |
| [traefik-resources.md](traefik-resources.md) | native CRDs: IngressRoute, Middleware (all types), TraefikService (weighted/mirror/failover), TLSOption, ServersTransport; router rules + priority |
| [traefik-operations.md](traefik-operations.md) | dashboard, prometheus metrics, access logs, tracing, troubleshooting 404/502/503/tls, scaling, upgrades, runbooks |
| [traefik-helm-argocd.md](traefik-helm-argocd.md) | helm values deep-dive, argocd app-of-apps, sync waves, CRD ownership, multi-cluster |
| [traefik-security.md](traefik-security.md) | tls/sni, cert-manager + ACME HA, dashboard auth, pod security, network policy, hardening, the snippet allowlist |

### hands-on tutorial

a runnable k3d course mirroring the envoy `eg-course` is under [../tutorial/](../tutorial/) — getting started, nginx baseline, flip to traefik, https, middlewares, canary, rate limiting, decommission nginx.

---

## quick reference commands

```bash
# is the nginx-compat provider seeing your ingresses?
kubectl logs -n traefik deploy/traefik | grep -iE 'ingress-nginx|kubernetesIngressNGINX'

# which ingressClasses exist and who owns them
kubectl get ingressclass

# traefik external IP
kubectl get svc -n traefik traefik

# router/service/middleware state via the api (port-forward the traefik entrypoint)
kubectl port-forward -n traefik deploy/traefik 8080:8080
curl -s localhost:8080/api/http/routers     | jq '.[].name'
curl -s localhost:8080/api/http/services    | jq '.[].name'
curl -s localhost:8080/api/http/middlewares | jq '.[].name'
curl -s localhost:8080/api/overview         | jq .

# test a host against traefik without changing dns
curl -v --resolve app.example.com:443:$(kubectl get svc -n traefik traefik \
  -o go-template='{{ (index .status.loadBalancer.ingress 0).ip }}') \
  https://app.example.com/

# tail traefik logs / access logs
kubectl logs -n traefik deploy/traefik --tail=100
kubectl logs -n traefik deploy/traefik | grep -E '"OriginStatus":(5|4)'

# native CRDs
kubectl get ingressroute,middleware,traefikservice,tlsoption,serverstransport -A

# back up everything traefik-owned + your ingresses
kubectl get ingress,ingressroute,middleware,traefikservice,tlsoption -A -o yaml > traefik-backup.yaml
```

---

## external references

- traefik docs: https://doc.traefik.io/traefik/
- nginx → traefik migration guide: https://doc.traefik.io/traefik/migrate/nginx-to-traefik/
- ingress-nginx migration tool: https://github.com/traefik/ingress-nginx-migration
- v3.7 announcement (nginx provider, 85+ annotations): https://traefik.io/blog/traefik-proxy-3-7-is-available
- traefik v3.7.1 release: https://github.com/traefik/traefik/releases/tag/v3.7.1
- helm chart: https://github.com/traefik/traefik-helm-chart  (chart 40.1.0+ = appVersion v3.7.1)
- kubernetesIngressNGINX provider reference: https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-ingress-nginx/
- traefik CRD reference: https://doc.traefik.io/traefik/reference/routing-configuration/kubernetes/crd/
