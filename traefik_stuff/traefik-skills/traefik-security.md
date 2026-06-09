# traefik - security & tls

tls/sni, cert-manager + ACME HA, dashboard auth, pod security, network policy, and the 3.7 snippet allowlist, for traefik v3.7.x on kubernetes.

---

## tls termination

### option A — secret-referenced certs (recommended, cert-manager-friendly)

terminate tls at traefik using a kubernetes `Secret` of type `kubernetes.io/tls`. for vanilla `Ingress` (and the nginx-compat provider) this is the `spec.tls[].secretName`; for `IngressRoute` it's `tls.secretName`.

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: { name: app, namespace: app-ns }
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`app.example.com`)
      kind: Rule
      services: [{ name: app-svc, port: 80 }]
  tls:
    secretName: app-tls            # kubernetes.io/tls secret in this namespace
    options: { name: modern-tls }  # TLSOption (ciphers/min version)
```

### option B — ACME / letsencrypt built into traefik

traefik can solve ACME itself (no cert-manager). but the **default file cert store is per-pod** — with >1 replica each pod solves independently and stores certs locally → duplicate orders, rate-limit pain, inconsistent certs.

```yaml
# helm values — single-replica or dev only with file store
certificatesResolvers:
  le:
    acme:
      email: platform@example.com
      storage: /data/acme.json
      httpChallenge: { entryPoint: web }
persistence: { enabled: true }     # PVC for acme.json
```

**for HA, do not use the file store.** either:
- use **cert-manager** (option A) — the standard at scale, certs live in Secrets shared by all replicas, **or**
- use a distributed ACME store (traefik enterprise / external KV).

> rule: more than one replica + letsencrypt ⇒ cert-manager. the file store does not coordinate across pods.

---

## cert-manager integration (the standard HA path)

cert-manager issues into a Secret; traefik just references it. all replicas read the same Secret.

```yaml
# 1. issuer (cluster-wide)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: letsencrypt-prod }
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: platform@example.com
    privateKeySecretRef: { name: letsencrypt-prod }
    solvers:
      - http01: { ingress: { ingressClassName: traefik } }   # or dns01
---
# 2. certificate -> writes app-tls Secret
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: app-tls, namespace: app-ns }
spec:
  secretName: app-tls
  issuerRef: { name: letsencrypt-prod, kind: ClusterIssuer }
  dnsNames: [ app.example.com ]
---
# 3. IngressRoute references the Secret (shown above, tls.secretName: app-tls)
```

migrating from nginx + cert-manager? the `Certificate` objects don't change — only the issuer's `solver.ingress.ingressClassName` flips from `nginx` to `traefik` once you cut over (or keep `nginx` while the class is still served by both).

---

## TLSOption — cipher & protocol hardening

replaces nginx `ssl-protocols` / `ssl-ciphers`. apply a modern policy and reference it from routes:

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSOption
metadata: { name: modern-tls, namespace: default }
spec:
  minVersion: VersionTLS12
  cipherSuites:
    - TLS_AES_128_GCM_SHA256
    - TLS_AES_256_GCM_SHA384
    - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
    - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
  curvePreferences: [ CurveP256, X25519 ]
  sniStrict: true                  # reject handshakes with no matching SNI cert (no default-cert leak)
```

**3.7 SNI note:** gateway api listeners now accept multiple `certificateRefs` (SNI-based selection), and `BackendTLSPolicy.caCertificateRefs` can come from a Secret — enabling end-to-end TLS with a private CA.

---

## mTLS to backends (ServersTransport)

replaces nginx `backend-protocol: HTTPS` + `proxy-ssl-*`. verify and/or present client certs to upstreams:

```yaml
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata: { name: app-mtls, namespace: app-ns }
spec:
  serverName: app-backend.app-ns.svc
  rootCAsSecrets: ["backend-ca"]          # verify the backend's server cert
  certificatesSecrets: ["traefik-client"] # present a client cert (mTLS)
  insecureSkipVerify: false               # never true in prod
  # 3.7: cipherSuites configurable here too
```

reference it from the route's `services[].serversTransport: app-mtls`.

### mTLS from clients (require client certs at the edge)

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSOption
metadata: { name: client-mtls, namespace: default }
spec:
  clientAuth:
    secretNames: ["client-ca"]            # CA that signs allowed client certs
    clientAuthType: RequireAndVerifyClientCert
```

---

## securing the dashboard / api

the `traefik` entrypoint (api + dashboard) must **never** be publicly reachable unauthenticated. options, strongest first:

1. **don't expose it at all** — access via `kubectl port-forward` only. default chart behavior (`ingressRoute.dashboard.enabled: false`).
2. **expose behind auth** — IngressRoute on `websecure` with a basicAuth (or forwardAuth/OIDC) middleware + ipAllowList:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata: { name: dashboard, namespace: traefik }
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`traefik.example.com`) && (PathPrefix(`/dashboard`) || PathPrefix(`/api`))
      kind: Rule
      middlewares:
        - name: dashboard-auth          # basicAuth or OIDC forwardAuth
        - name: internal-only           # ipAllowList to admin CIDRs
      services:
        - name: api@internal            # the built-in api service
          kind: TraefikService
  tls: { secretName: traefik-dashboard-tls }
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: dashboard-auth, namespace: traefik }
spec:
  basicAuth: { secret: traefik-dashboard-users }
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: internal-only, namespace: traefik }
spec:
  ipAllowList: { sourceRange: ["10.0.0.0/8"] }
```

never set `api.insecure: true` in production (it exposes the api on the traefik entrypoint with no auth).

---

## pod security

```yaml
# helm values
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  fsGroup: 65532
securityContext:
  capabilities:
    drop: ["ALL"]
    add: ["NET_BIND_SERVICE"]      # only if binding :80/:443 directly; with exposedPort mapping you may not need it
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
```

works under PSA `restricted` with the above. if `readOnlyRootFilesystem: true`, mount an `emptyDir` for any writable path (e.g. ACME storage if you insist on the file store).

namespace label:

```yaml
pod-security.kubernetes.io/enforce: restricted
```

---

## network policy

lock down who can reach traefik and what traefik can reach:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: traefik, namespace: traefik }
spec:
  podSelector: { matchLabels: { app.kubernetes.io/name: traefik } }
  policyTypes: [Ingress, Egress]
  ingress:
    - from: []                       # LB / world to :80/:443 (data plane)
      ports: [{ port: 8000 }, { port: 8443 }]
    - from:                          # api/metrics only from monitoring ns
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: monitoring } }
      ports: [{ port: 8080 }]
  egress:
    - to: []                          # to backends (tighten to app namespaces in real policy)
    - to:                             # kube-apiserver (watch CRDs/Ingress)
        - namespaceSelector: {}
      ports: [{ port: 443 }, { port: 6443 }]
```

---

## the snippet allowlist (3.7 security model)

nginx `*-snippet` annotations let users inject raw nginx config — a classic injection/escape surface (the ingress-nginx CVE history is largely snippet-driven). traefik 3.7 **does not execute snippets raw**. it:

1. **parses** snippet content into structured input,
2. **maps** it against a **curated allowlist** of safe directives — header manipulation, rewrites, variable interpolation for client IPs and URI components,
3. **rejects everything else.**

implications for migration:
- snippets doing header/rewrite/IP/URI work → translated automatically.
- snippets doing anything else (lua, `proxy_pass` overrides, arbitrary directives, access to nginx internals) → **rejected**; re-express the intent as a traefik `Middleware`.
- this is a feature: it closes the snippet injection class entirely. audit your snippets (`audit` tool in the migration doc) before cutover so nothing silently drops.

---

## hardening checklist

- [ ] dashboard/api not publicly exposed (port-forward, or auth + ipAllowList; never `api.insecure`)
- [ ] tls via cert-manager Secrets (not file-store ACME) when replicas > 1
- [ ] `TLSOption`: minVersion TLS1.2+, modern ciphers, `sniStrict: true`
- [ ] mTLS to sensitive backends via `ServersTransport` (`insecureSkipVerify: false`)
- [ ] pod runs non-root, drops caps, read-only rootfs, PSA `restricted`
- [ ] NetworkPolicy restricts api/metrics port to monitoring only
- [ ] snippets audited; non-allowlisted ones re-expressed as Middleware
- [ ] `allowCrossNamespace`/`allowExternalNameServices` left **false** unless explicitly needed
- [ ] on traefik **v3.7.1+** (fixes CVE-2026-44774 / GHSA-96qj-4jj5-wcjc)

---

## references

- tls overview: https://doc.traefik.io/traefik/https/tls/
- ACME: https://doc.traefik.io/traefik/https/acme/
- cert-manager: https://cert-manager.io/docs/usage/ingress/
- dashboard security: https://doc.traefik.io/traefik/operations/dashboard/
- 3.7 snippet allowlist + gateway-api tls: https://traefik.io/blog/traefik-proxy-3-7-is-available
- v3.7.1 / CVE-2026-44774: https://github.com/traefik/traefik/releases/tag/v3.7.1
