# takeaways

what migrating from ingress-nginx to traefik 3.7.1 actually looked like.

## the one-line summary

> migrating off ingress-nginx with traefik 3.7 is a **dns cutover, not a manifest rewrite**. your `Ingress` objects — `ingressClassName: nginx`, every `nginx.ingress.kubernetes.io/*` annotation — stay byte-for-byte unchanged. traefik reads and serves them.

## the migration shape

```
1. inventory annotations (flag snippets/lua — those need hands)
2. install traefik 3.7.1, kubernetesIngressNGINX provider ON,
   publishService OFF, isDefaultClass OFF  (coexist with nginx)
3. verify parity against traefik's IP via --resolve (no dns change)
4. dns / weighted-LB cutover, soak 24-48h
5. PRESERVE the nginx IngressClass, delete webhooks, uninstall nginx
6. flip publishService ON + isDefaultClass ON
7. (optional, ongoing) refactor hot paths to native CRDs
```

## what translated automatically (you wrote zero traefik yaml)

- tls termination + `ssl-redirect` / `force-ssl-redirect`
- `proxy-body-size`, `proxy-read-timeout`, buffering
- `enable-cors` + `cors-*`
- `limit-rps` / `limit-connections` → rateLimit / inFlightReq
- `whitelist-source-range` → ipAllowList
- `canary` / `canary-weight` → weighted split
- 85+ annotations total, >90% of real usage

## what needed a human

- `*-snippet` annotations → parsed against a **safe allowlist** (header/rewrite/IP/URI), everything else rejected → re-express as `Middleware`
- lua / `*-by-lua` → no equivalent, re-implement
- nginx worker tuning → irrelevant (traefik is a Go process; tune replicas/resources)

## the three traps that bite people

1. **deleting the IngressClass.** `helm uninstall ingress-nginx` removes the `nginx` class and 404s everything. pin it with `helm.sh/resource-policy: keep` first.
2. **the status race.** both controllers write `Ingress .status`. set `publishService.enabled: false` on traefik during coexistence.
3. **strictValidatePathType (3.7 default true).** nginx tolerated odd/empty `pathType`; traefik validates strictly. fix the Ingress, or relax the flag.

## traefik vs envoy gateway (the sibling course)

| | envoy gateway | traefik 3.7 |
|---|---|---|
| migration off nginx | rewrite Ingress → Gateway+HTTPRoute | **reuse Ingress unchanged** |
| architecture | controller + per-gateway envoy fleets (xDS) | single Go process, N replicas |
| config model | gateway api CRDs only | nginx annotations **or** native CRDs **or** gateway api |
| nginx annotation support | none (must convert) | 85+ native |
| best when | standardizing on gateway api greenfield | **replacing ingress-nginx with least churn** |

both are valid. traefik 3.7 wins specifically on **lowest-friction nginx replacement**; envoy gateway wins on **pure gateway-api standardization**.

## where to go next

- `traefik-skills/traefik-nginx-migration.md` — the full annotation map + fleet rollout
- `traefik-skills/traefik-resources.md` — native CRD catalog (Middleware/TraefikService/TLSOption)
- `traefik-skills/traefik-operations.md` — dashboard, metrics, troubleshooting
- `traefik-skills/traefik-helm-argocd.md` — gitops at fleet scale
- `traefik-skills/traefik-security.md` — tls/mTLS, cert-manager HA, hardening

## teardown

```bash
k3d cluster delete traefik-course
```
