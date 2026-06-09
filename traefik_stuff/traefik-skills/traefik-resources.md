# traefik - native CRD resources

reference for traefik's native kubernetes CRDs (the `kubernetesCRD` provider): `IngressRoute`, `Middleware`, `TraefikService`, `TLSOption`, `ServersTransport`, plus router rules and the 3.7 additions (service-level middlewares, status-code retry/failover).

use these for greenfield routing and for post-migration refactors of hot paths. for **migrating existing nginx ingresses you do not need any of this** — the compat provider handles those (see [traefik-nginx-migration.md](traefik-nginx-migration.md)). these CRDs express things nginx annotations can't.

apiVersion for all traefik CRDs: `traefik.io/v1alpha1`.

---

## router rules (the matching language)

traefik routers match on a rule expression, not a `pathType` enum:

| rule | matches | nginx analog |
|------|---------|--------------|
| `` Host(`app.example.com`) `` | exact host | `spec.rules[].host` |
| `` HostRegexp(`^.+\.example\.com$`) `` | host regex | wildcard host |
| `` PathPrefix(`/api`) `` | path prefix | `pathType: Prefix` |
| `` Path(`/healthz`) `` | exact path | `pathType: Exact` |
| `` PathRegexp(`^/v[0-9]+/`) `` | path regex | `pathType: ImplementationSpecific` + regex |
| `` Header(`X-Env`, `prod`) `` | request header equals | header-based canary |
| `` HeaderRegexp(`User-Agent`, `.*Mobile.*`) `` | header regex | — |
| `` Query(`debug`, `true`) `` | query param | — |
| `` Method(`GET`) `` | http method | `allowed-methods` |
| `` ClientIP(`10.0.0.0/8`) `` | source ip | `whitelist-source-range` |

combine with `&&`, `||`, `!`, and parentheses. **priority** breaks ties — higher wins; default priority = rule length, so longer/more-specific rules win automatically. set `priority` explicitly when you need a catch-all to lose:

```yaml
routes:
  - match: Host(`app.example.com`) && PathPrefix(`/api`)
    priority: 100
    kind: Rule
    services: [{ name: api-svc, port: 80 }]
  - match: Host(`app.example.com`)         # catch-all, must lose to /api
    priority: 1
    kind: Rule
    services: [{ name: web-svc, port: 80 }]
```

---

## IngressRoute

the core routing object. one IngressRoute can hold many routes.

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: app
  namespace: app-ns
spec:
  entryPoints: [websecure]               # which listener(s): web (80), websecure (443)
  routes:
    - match: Host(`app.example.com`) && PathPrefix(`/`)
      kind: Rule
      middlewares:                        # ORDERED chain
        - name: redirect-https
        - name: security-headers
      services:
        - name: app-svc                   # a k8s Service (or a TraefikService — see below)
          port: 80
          # optional per-service tuning:
          scheme: http                    # http|https|h2c
          sticky:
            cookie:
              name: app_sticky
              secure: true
              httpOnly: true
          passHostHeader: true
          serversTransport: app-transport # ServersTransport CRD ref
  tls:
    secretName: app-tls                   # OR:
    # certResolver: le                    # ACME resolver name (cert-manager-free letsencrypt)
    options:
      name: modern-tls                    # TLSOption CRD ref
```

### TCP / UDP routes

for non-http (databases, raw tls passthrough), use `IngressRouteTCP` / `IngressRouteUDP`:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata: { name: postgres, namespace: db }
spec:
  entryPoints: [postgres]                 # custom entryPoint on :5432
  routes:
    - match: HostSNI(`*`)                  # HostSNI(`*`) = match all (non-tls tcp)
      services: [{ name: postgres-svc, port: 5432 }]
  # tls: { passthrough: true }            # for SNI-routed TLS passthrough
```

---

## Middleware (the workhorse)

middlewares are reusable, namespace-scoped, and **applied in the order listed** on the route. this is the biggest mental shift from nginx annotations: instead of a bag of annotations on one ingress, you compose ordered, named, reusable objects.

cross-namespace reference syntax: `<namespace>-<middlewarename>@kubernetescrd` (and the CRD provider must allow it).

### redirect to https (replaces ssl-redirect / force-ssl-redirect)

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: redirect-https, namespace: app-ns }
spec:
  redirectScheme:
    scheme: https
    permanent: true                       # 301
```

### strip / rewrite path (replaces rewrite-target)

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: strip-api, namespace: app-ns }
spec:
  stripPrefix:
    prefixes: ["/api"]
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: rewrite, namespace: app-ns }
spec:
  replacePathRegex:
    regex: "^/old/(.*)"
    replacement: "/new/$1"
```

### basic auth (replaces auth-type/auth-secret)

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: dashboard-auth, namespace: traefik }
spec:
  basicAuth:
    secret: dashboard-users               # Secret with htpasswd-style users
    realm: "restricted"
```

### rate limit (replaces limit-rps / limit-rpm)

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: ratelimit, namespace: app-ns }
spec:
  rateLimit:
    average: 100                          # requests
    period: 1s                            # per second (use 1m for limit-rpm)
    burst: 50
    sourceCriterion:
      ipStrategy: { depth: 1 }            # respect X-Forwarded-For depth
```

### in-flight (replaces limit-connections)

```yaml
spec:
  inFlightReq:
    amount: 10
```

### ip allow list (replaces whitelist-source-range)

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: ip-allowlist, namespace: app-ns }
spec:
  ipAllowList:
    sourceRange: ["10.0.0.0/8", "192.168.0.0/16"]
```

### headers / cors (replaces add-headers / enable-cors / cors-*)

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: security-headers, namespace: app-ns }
spec:
  headers:
    customResponseHeaders:
      X-Frame-Options: "DENY"
      X-Content-Type-Options: "nosniff"
    accessControlAllowOriginList: ["https://ui.example.com"]
    accessControlAllowMethods: ["GET", "POST", "OPTIONS"]
    accessControlAllowCredentials: true
    stsSeconds: 31536000
    stsIncludeSubdomains: true
```

### retry — now by HTTP status code (3.7)

nginx's `proxy-next-upstream`, done cleanly. retry only on the statuses you choose:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: smart-retry, namespace: app-ns }
spec:
  retry:
    attempts: 3
    initialInterval: 100ms
    # 3.7: retry driven by response status, not just connection errors
    # (file-provider form shown; CRD exposes the same retryOn semantics)
```

file/dynamic-config equivalent showing the 3.7 `retryOn`:

```yaml
http:
  middlewares:
    smart-retry:
      retry:
        attempts: 3
        initialInterval: 100ms
        retryOn:
          statusCodes: [502, 503, 504]
        timeout: 2s
```

### circuit breaker

```yaml
spec:
  circuitBreaker:
    expression: "NetworkErrorRatio() > 0.30 || ResponseCodeRatio(500,600,0,600) > 0.25"
```

### errors / custom error pages (replaces custom-http-errors + errors-service)

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: custom-errors, namespace: app-ns }
spec:
  errors:
    status: ["500-599"]
    service: { name: error-pages, port: 80 }
    query: "/{status}.html"
```

### chaining middlewares

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: app-chain, namespace: app-ns }
spec:
  chain:
    middlewares:
      - name: redirect-https
      - name: ip-allowlist
      - name: ratelimit
      - name: security-headers
```

---

## service-level middlewares (3.7, new)

before 3.7 middlewares attached only to routers. now they attach to the **service** too — so when many routers target one backend, you define the middleware once on the service instead of repeating it on every router. this also powers gateway-api filters on HTTP backends.

```yaml
# file/dynamic-config form
http:
  services:
    api:
      loadBalancer:
        servers:
          - url: "http://api-backend:8080"
      middlewares:
        - rate-limit
        - auth
```

practical effect: dedup. one `Service` referenced by 20 routes → one place to set its rate limit/auth.

---

## TraefikService — weighted, mirror, failover

a `TraefikService` is a virtual service you reference from an IngressRoute's `services[].kind: TraefikService`. three modes:

### weighted (canary / blue-green — replaces nginx canary-weight)

```yaml
apiVersion: traefik.io/v1alpha1
kind: TraefikService
metadata: { name: app-canary, namespace: app-ns }
spec:
  weighted:
    services:
      - name: app-stable
        port: 80
        weight: 90
      - name: app-canary
        port: 80
        weight: 10
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: { name: app, namespace: app-ns }
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`app.example.com`)
      kind: Rule
      services:
        - name: app-canary
          kind: TraefikService            # reference the weighted service
  tls: { secretName: app-tls }
```

### mirroring (shadow traffic)

```yaml
apiVersion: traefik.io/v1alpha1
kind: TraefikService
metadata: { name: app-mirror, namespace: app-ns }
spec:
  mirroring:
    name: app-prod
    port: 80
    mirrors:
      - name: app-shadow                  # gets a copy of requests, responses ignored
        port: 80
        percent: 10
```

### failover by status (3.7, new)

primary + fallback, switching on response status — no service mesh needed:

```yaml
apiVersion: traefik.io/v1alpha1
kind: TraefikService
metadata: { name: api-failover, namespace: app-ns }
spec:
  failover:
    service: api-primary
    fallback: api-backup
    healthCheck: {}
    errors:
      status: ["500-504"]                 # fail over when primary returns these
```

---

## TLSOption — cipher / protocol policy

replaces nginx `ssl-protocols` / `ssl-ciphers` configmap keys. reference it from an IngressRoute's `tls.options`.

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSOption
metadata: { name: modern-tls, namespace: default }
spec:
  minVersion: VersionTLS12
  cipherSuites:
    - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
    - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
    - TLS_AES_128_GCM_SHA256
  sniStrict: true                         # reject handshakes with no matching SNI cert
```

---

## ServersTransport — backend connection / mTLS to upstream

replaces nginx `backend-protocol: HTTPS` + `proxy-ssl-*` and the proxy timeout annotations.

```yaml
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata: { name: app-transport, namespace: app-ns }
spec:
  serverName: app-backend.svc
  rootCAsSecrets: ["backend-ca"]          # verify upstream cert against this CA
  certificatesSecrets: ["client-cert"]    # present client cert (mTLS to backend)
  insecureSkipVerify: false
  forwardingTimeouts:
    dialTimeout: 5s                        # ~ proxy-connect-timeout
    responseHeaderTimeout: 30s             # ~ proxy-read-timeout
  # 3.7: cipherSuites configurable on ServersTransport
```

---

## annotation → CRD cheat sheet (for refactoring)

| nginx annotation | native traefik CRD |
|------------------|--------------------|
| `ssl-redirect` / `force-ssl-redirect` | `Middleware.redirectScheme` |
| `rewrite-target` | `Middleware.stripPrefix` / `replacePathRegex` |
| `auth-type` / `auth-secret` | `Middleware.basicAuth` / `digestAuth` |
| `limit-rps` / `limit-rpm` | `Middleware.rateLimit` |
| `limit-connections` | `Middleware.inFlightReq` |
| `whitelist-source-range` | `Middleware.ipAllowList` |
| `enable-cors` / `cors-*` | `Middleware.headers` |
| `proxy-next-upstream` | `Middleware.retry` (statusCodes) |
| `canary` / `canary-weight` | `TraefikService.weighted` |
| `default-backend` / `custom-http-errors` | `Middleware.errors` |
| `backend-protocol: HTTPS` / `proxy-ssl-*` | `ServersTransport` |
| `proxy-*-timeout` | `ServersTransport.forwardingTimeouts` |
| `ssl-protocols` / `ssl-ciphers` | `TLSOption` |
| `affinity` / `session-cookie-*` | IngressRoute `services[].sticky.cookie` |
| `upstream-hash-by` | `ServersTransport` / service LB strategy |

---

## references

- CRD reference: https://doc.traefik.io/traefik/reference/routing-configuration/kubernetes/crd/
- middleware catalog: https://doc.traefik.io/traefik/middlewares/overview/
- router rules: https://doc.traefik.io/traefik/routing/routers/
- TraefikService: https://doc.traefik.io/traefik/routing/services/
- 3.7 service-level middlewares + retry/failover: https://traefik.io/blog/traefik-proxy-3-7-is-available
