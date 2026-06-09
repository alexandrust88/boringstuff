# traefik - nginx ingress migration guide

migrating from **ingress-nginx** to **traefik proxy v3.7.x** with zero ingress-manifest changes, using the native `kubernetesIngressNGINX` compatibility provider.

> the headline of traefik 3.7: it reads your existing `Ingress` objects (`ingressClassName: nginx`) and translates 85+ `nginx.ingress.kubernetes.io/*` annotations natively, covering >90% of real-world usage. migration is **dns cutover**, not **manifest rewrite**.

requires traefik **v3.6.2+** (use **v3.7.1**, helm chart **40.1.0+**).

---

## the big idea: you do not rewrite your ingresses

with envoy gateway, migrating off nginx means rewriting every `Ingress` into a `Gateway` + `HTTPRoute`. with traefik 3.7's compat provider you **keep the exact same `Ingress` objects** — same `ingressClassName: nginx`, same annotations — and just stand traefik up next to nginx. traefik parses the annotations and serves the same routes.

```
your existing Ingress (UNCHANGED):
  ingressClassName: nginx
  nginx.ingress.kubernetes.io/ssl-redirect: "true"
  nginx.ingress.kubernetes.io/proxy-body-size: "50m"
        |
        | ingress-nginx reads it   ----> serves on nginx LB IP (real dns today)
        | traefik reads it TOO     ----> serves on traefik LB IP (test, then dns)
        v
  both controllers produce equivalent routing from the same manifest
```

cutover is: deploy traefik → validate against same manifests → shift dns → delete nginx. native CRDs (`IngressRoute`/`Middleware`) are **optional** and can come later, route by route, only where you want them.

---

## step 0: inventory what you have

before anything, know what annotations and configmap keys are in play — some don't translate (snippets, lua, worker tuning).

```bash
# every nginx annotation in the cluster, ranked by frequency
kubectl get ingress -A -o json \
| jq -r '.items[].metadata.annotations // {} | keys[]' \
| grep '^nginx.ingress.kubernetes.io/' | sort | uniq -c | sort -rn

# ingresses that use snippets (these need manual attention)
kubectl get ingress -A -o json \
| jq -r '.items[] | select(.metadata.annotations // {} | keys[] | test("snippet"))
         | "\(.metadata.namespace)/\(.metadata.name)"'

# the ingress-nginx ConfigMap (global tuning you may need to map)
kubectl get cm -n ingress-nginx ingress-nginx-controller -o yaml
```

or use the official audit tool, which flags unsupported annotations per ingress:

```bash
# https://github.com/traefik/ingress-nginx-migration
# audits manifests and reports what will/won't translate
go run github.com/traefik/ingress-nginx-migration@latest audit --all-namespaces
```

---

## step 1: enable the kubernetesIngressNGINX provider

helm values:

```yaml
providers:
  kubernetesIngressNGINX:
    enabled: true
    controllerClass: "k8s.io/ingress-nginx"   # match what your Ingresses target
    # IMPORTANT during coexistence — see step 3:
    publishService:
      enabled: false
```

the provider auto-discovers `Ingress` objects with `ingressClassName: nginx` (or the legacy `kubernetes.io/ingress.class: nginx` annotation) and builds traefik routers/middlewares/services from their annotations.

### global static-config defaults (the ingress-nginx ConfigMap equivalents)

ingress-nginx had a cluster-wide ConfigMap. traefik exposes the equivalent global defaults on the provider; per-ingress annotations still override them:

```yaml
providers:
  kubernetesIngressNGINX:
    enabled: true
    proxyConnectTimeout: 5            # seconds
    proxyBuffering: true
    proxyRequestBuffering: true
    clientBodyBufferSize: 8k
    proxyBodySize: 1m                 # global max body (per-ingress: proxy-body-size)
    proxyBufferSize: 4k
    proxyBuffersNumber: 4
    proxyNextUpstream: "error timeout http_502 http_503 http_504"
    proxyNextUpstreamTimeout: 0
    proxyNextUpstreamTries: 3
    customHTTPErrors: []
    defaultBackendService: ""         # ns/name of a catch-all backend
    globalAllowedResponseHeaders: []
    allowCrossNamespaceResources: false
    strictValidatePathType: true      # default true in 3.7 — see gotchas
    publishService:
      enabled: false
```

---

## step 2: the annotation mapping (what becomes what)

you don't write these — the provider does — but you need the table to (a) trust the translation and (b) know what to do with the unsupported ones.

### supported annotation groups (85+, the >90% set)

**authentication & authorization**

| nginx annotation | traefik behavior |
|------------------|------------------|
| `auth-type` (basic\|digest) | basicAuth / digestAuth middleware |
| `auth-secret` | credentials from referenced Secret |
| `auth-realm` | realm string on the auth middleware |
| `auth-response-headers` | headers forwarded from auth to backend |

**session affinity (sticky sessions)**

| nginx annotation | traefik behavior |
|------------------|------------------|
| `affinity` (cookie\|clientip) | sticky session on the service |
| `affinity-mode` (persistent\|balanced) | sticky persistence behavior |
| `session-cookie-name` | sticky cookie name |
| `session-cookie-path` | sticky cookie path |
| `session-cookie-secure` | sticky cookie Secure flag |

**routing & redirects**

| nginx annotation | traefik behavior |
|------------------|------------------|
| `ssl-redirect` | redirect-to-https middleware on the :80 router |
| `force-ssl-redirect` | always redirect to https (even behind proxied TLS) |
| `rewrite-target` | replacePathRegex / stripPrefix middleware |
| `permanent-redirect` | 301 redirect middleware |
| `temporal-redirect` | 307 redirect middleware |

**proxy & buffering**

| nginx annotation | traefik behavior |
|------------------|------------------|
| `proxy-connect-timeout` | serversTransport dial timeout |
| `proxy-send-timeout` | write timeout |
| `proxy-read-timeout` | response/read timeout |
| `proxy-body-size` | max request body |
| `proxy-buffering` / `proxy-request-buffering` | response/request buffering toggles |
| `proxy-buffer-size` / `proxy-buffers-number` | buffer sizing |

**load balancing**

| nginx annotation | traefik behavior |
|------------------|------------------|
| `upstream-hash-by` | consistent-hash load balancing key |
| `upstream-fail-timeout` / `upstream-max-fails` | passive health detection window/threshold |

**rate limiting**

| nginx annotation | traefik behavior |
|------------------|------------------|
| `limit-rps` | rateLimit middleware (per second) |
| `limit-rpm` | rateLimit middleware (per minute) |
| `limit-connections` | inFlightReq middleware |
| `limit-whitelist` | sources exempt from rate limiting |

**canary deployments**

| nginx annotation | traefik behavior |
|------------------|------------------|
| `canary` | enables weighted/conditional split |
| `canary-by-header` / `canary-by-header-value` | header-based routing to canary |
| `canary-by-cookie` | cookie-based routing to canary |
| `canary-weight` | percentage traffic to canary service |

**http headers / cors**

| nginx annotation | traefik behavior |
|------------------|------------------|
| `add-headers` / `custom-headers` | headers middleware (request/response inject) |
| `enable-cors` + `cors-allow-origin/methods/credentials` | cors via headers middleware |
| `enable-modsecurity` | WAF integration (where wired) |

**error handling**

| nginx annotation | traefik behavior |
|------------------|------------------|
| `default-backend` / `errors-service` | errors middleware → fallback service |
| `custom-http-errors` | per-status error-page routing |

**access control**

| nginx annotation | traefik behavior |
|------------------|------------------|
| `whitelist-source-range` | ipAllowList middleware |
| `allowed-methods` | method-restricting middleware |
| `deny-access-filename` | path-deny rule |

**observability**

| nginx annotation | traefik behavior |
|------------------|------------------|
| `enable-access-log` | access log toggle for the route |
| `log-format-upstream` | custom access-log format |
| `enable-metrics` | metric collection for the route |

### unsupported — these need a human

these are nginx-specific and have **no automatic translation**. translate the *intent*, not the directive:

| nginx thing | what to do |
|-------------|------------|
| `main-snippet` / `http-snippet` / `server-snippet` / `configuration-snippet` | 3.7 parses snippet content against a **curated safe allowlist** (header manipulation, rewrites, client-IP/URI variable interpolation) and **rejects everything else**. anything outside the allowlist must be re-expressed as a traefik `Middleware`. |
| `lua` directives / `*-by-lua` | no equivalent. re-implement as middleware, ext-auth, or plugin. |
| nginx worker/`worker-processes`/`worker-connections` tuning | irrelevant — traefik is a Go process, tune replicas + resources instead. |
| raw `nginx.conf` ConfigMap keys that are nginx-internal | drop them; they describe nginx's engine, not your routing intent. |
| `modsecurity-snippet` raw rules | use a WAF middleware/plugin or external WAF. |

**rule of thumb:** if the audit tool flags an ingress, it's almost always a snippet or lua. handle those by hand as `Middleware`; everything else flows automatically.

---

## step 3: run nginx and traefik in parallel (the status race)

both controllers will watch the **same** `nginx` IngressClass and serve the **same** `Ingress` objects. that's intended — it's how you A/B test. but both will also try to write their LoadBalancer address into `status.loadBalancer.ingress[]` on every Ingress, fighting each other.

### fix — option 1 (recommended): disable traefik status publishing

```yaml
providers:
  kubernetesIngressNGINX:
    publishService:
      enabled: false        # traefik serves traffic but won't touch Ingress .status
```

nginx keeps owning `.status` (so external-dns / tooling keyed on it stay correct) while traefik quietly serves the same routes on its own LB IP. flip this back to `true` after nginx is gone.

### fix — option 2: transitional IngressClass

give the two controllers **different** classes so they never co-own an Ingress. e.g. point traefik at a temporary `nginx-traefik` class, copy a few ingresses onto it, validate, then move the rest. more isolation, more manifest churn — use it when you want a controlled blast radius per app.

### verify traefik serves the same routes — without touching dns

```bash
TRAEFIK_IP=$(kubectl get svc -n traefik traefik \
  -o go-template='{{ $i := index .status.loadBalancer.ingress 0 }}{{ if $i.ip }}{{ $i.ip }}{{ else }}{{ $i.hostname }}{{ end }}')

# --connect-to / --resolve forces the hostname at traefik's IP, bypassing dns
curl --connect-to "app.example.com:443:${TRAEFIK_IP}:443" https://app.example.com/healthz
curl --resolve     "app.example.com:443:${TRAEFIK_IP}"     https://app.example.com/api/version

# compare against nginx for the same host
NGINX_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o go-template='{{ (index .status.loadBalancer.ingress 0).ip }}')
curl --resolve "app.example.com:443:${NGINX_IP}" https://app.example.com/healthz
```

if both return the same thing, traefik is a faithful stand-in for that ingress.

---

## step 4: dns cutover

### pre-cutover (24-48h before): lower TTL

```bash
# lower dns ttl to 60s for fast failover (provider-specific; route53 example)
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch '{
  "Changes":[{"Action":"UPSERT","ResourceRecordSet":{
    "Name":"app.example.com","Type":"A","TTL":60,
    "ResourceRecords":[{"Value":"'"$NGINX_IP"'"}]}}]}'
```

### cutover strategy A — progressive dns (simple)

1. add traefik's LB IP **alongside** nginx's on the dns record (both receive traffic, round-robin)
2. watch error rates / latency on both controllers' metrics
3. remove nginx's IP from dns
4. wait 24-48h for caches to expire (some resolvers ignore TTL)

### cutover strategy B — external LB weighted shift (controlled)

put an infra LB in front of both k8s LoadBalancers and shift weight:

| phase | nginx | traefik | gate to advance |
|-------|-------|---------|-----------------|
| 0 | 100% | 0% | traefik healthy, routes verified |
| 1 | 90% | 10% | 5xx delta < 0.1%, p99 stable |
| 2 | 50% | 50% | no new error classes |
| 3 | 10% | 90% | sustained 1h |
| 4 | 0% | 100% | full cutover |

### post-cutover validation

```bash
dig app.example.com +short                                   # points at traefik now
curl -I https://app.example.com/healthz                      # 200
grpcurl -insecure app.example.com:443 list 2>/dev/null || true  # grpc if applicable
kubectl logs -n traefik deploy/traefik | grep -E '"OriginStatus":5' | tail   # backend 5xx?
# restore normal dns ttl after 24-48h stable
```

---

## step 5: rollback

dns ttl is already 60s, so rollback is fast:

```bash
# A) dns rollback: point record back at nginx IP (fastest)

# B) make traefik stop owning the route entirely
#    (only needed if traefik is misbehaving on a shared class)
kubectl annotate ingress app -n app-ns \
  kubernetes.io/ingress.class=nginx --overwrite   # if you'd used a transitional class

# C) confirm nginx still serves
curl --resolve "app.example.com:443:${NGINX_IP}" https://app.example.com/healthz
```

rollback decision criteria:

| symptom | severity | action |
|---------|----------|--------|
| app unreachable via traefik | critical | dns rollback immediately |
| tls/sni errors (wrong cert) | high | check cert secret + TLSOption, rollback if not fixed in 5 min |
| 5xx > 1% above nginx baseline | medium | inspect backend + middleware order, rollback if persists |
| latency +200% | medium | check buffering/timeouts, rollback if persists |
| a few annotations not honored | low | likely unsupported snippet — handle as Middleware, don't roll back the whole cutover |

---

## step 6: decommission ingress-nginx (carefully)

the trap: if ingress-nginx was helm-installed, `helm uninstall` will **delete the `nginx` IngressClass** — and traefik needs it to keep matching your ingresses. **preserve the IngressClass first.**

```bash
# 1. pin the IngressClass so helm won't delete it
helm upgrade ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  -n ingress-nginx --reuse-values \
  --set-json 'controller.ingressClassResource.annotations={"helm.sh/resource-policy":"keep"}'

#   (gitops-managed instead? add a standalone IngressClass resource to your repo,
#    owned separately from the nginx release, so it survives the release deletion.)

# 2. remove the admission webhooks (they block Ingress writes once the controller is gone)
kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found
kubectl delete mutatingwebhookconfiguration   ingress-nginx-admission --ignore-not-found

# 3. uninstall nginx
helm uninstall ingress-nginx -n ingress-nginx
kubectl delete namespace ingress-nginx

# 4. confirm the class survived — traefik depends on it
kubectl get ingressclass nginx

# 5. now flip traefik to own status + (optionally) become default class
#    helm values:
#      providers.kubernetesIngressNGINX.publishService.enabled: true
#      ingressClass.isDefaultClass: true
```

after this, traefik is the sole controller, still serving your unchanged `Ingress` objects.

---

## step 7 (optional, ongoing): refactor hot paths to native CRDs

you never have to, but native CRDs unlock things nginx annotations can't express cleanly:
service-level middlewares, status-code-driven retry/failover (new in 3.7), mirroring, reusable
`Middleware` objects, `TLSOption` cipher policy. migrate **route by route**, not big-bang.
see [traefik-resources.md](traefik-resources.md).

```yaml
# before: Ingress + nginx annotations  (keeps working)
# after:  IngressRoute + reusable Middleware (clearer, more powerful)
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: { name: app, namespace: app-ns }
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`app.example.com`) && PathPrefix(`/api`)
      kind: Rule
      middlewares:
        - name: ratelimit          # was nginx.ingress.kubernetes.io/limit-rps
        - name: ip-allowlist       # was whitelist-source-range
      services:
        - name: app-svc
          port: 80
  tls:
    secretName: app-tls
```

---

## migration checklist

- [ ] inventory annotations + flag snippets/lua (`audit` tool)
- [ ] decide global ConfigMap → provider static defaults mapping
- [ ] install traefik 40.1.0+ with `kubernetesIngressNGINX.enabled: true`
- [ ] set `publishService.enabled: false` for coexistence
- [ ] keep `ingressClass.isDefaultClass: false` while nginx is live
- [ ] verify each critical host against traefik IP via `--resolve` (no dns change)
- [ ] re-express snippet/lua ingresses as native `Middleware`
- [ ] lower dns ttl to 60s
- [ ] progressive dns or weighted external-LB cutover
- [ ] post-cutover validation (status, tls, 5xx, latency)
- [ ] 24-48h soak
- [ ] **preserve `nginx` IngressClass** (`helm.sh/resource-policy: keep`)
- [ ] delete nginx admission webhooks
- [ ] uninstall ingress-nginx, delete namespace
- [ ] confirm IngressClass survived
- [ ] flip traefik `publishService.enabled: true` + `isDefaultClass: true`
- [ ] (optional) refactor hot paths to IngressRoute/Middleware over time

---

## references

- nginx → traefik official guide: https://doc.traefik.io/traefik/migrate/nginx-to-traefik/
- kubernetesIngressNGINX provider reference: https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-ingress-nginx/
- migration audit tool: https://github.com/traefik/ingress-nginx-migration
- 3.7 announcement: https://traefik.io/blog/traefik-proxy-3-7-is-available
- "measure twice, cut once" audit blog: https://traefik.io/blog (ingress-nginx migration post)
