# traefik_stuff

traefik proxy **v3.7.1** on kubernetes as a **drop-in replacement for ingress-nginx**. reference docs + a runnable hands-on course, built to mirror the `../traefik_stuff`-sibling envoy gateway material (`../gateway-skills/`, `../argocd-envoy/tutorial/`).

> why now: traefik 3.7 ("langres", released 2026-05-06) ships the `kubernetesIngressNGINX` provider as GA — it reads your existing `Ingress` objects and translates **85+ `nginx.ingress.kubernetes.io/*` annotations natively** (>90% of real usage). migrating off ingress-nginx becomes a **dns cutover, not a manifest rewrite**.

## versions

| component | version | note |
|-----------|---------|------|
| traefik proxy | `v3.7.1` | nginx provider GA; v3.7.1 adds `CrossProviderNamespaces`, fixes CVE-2026-44774 |
| traefik helm chart | `40.1.0` / `40.2.0` | these bundle appVersion `v3.7.1`. **chart is `40.x`, not `0.40.0`** — `40.0.0` bundled `v3.7.0` |
| nginx provider min | traefik `v3.6.2+` | use 3.7.x for GA + annotation breadth |

## layout

```
traefik_stuff/
├── README.md                 ← you are here
├── traefik-skills/           reference docs (the lookup tables)
│   ├── SKILL.md              overview, architecture, quickstart, helm patterns, commands
│   ├── traefik-nginx-migration.md   ★ the core doc: provider, annotation map, coexistence, cutover, decommission
│   ├── traefik-nginx-migration-azure-ip-reuse.md  ★ azure aks: same public ip, no dns change (selector-swap vs ip-move)
│   ├── traefik-resources.md  native CRDs: IngressRoute, Middleware, TraefikService, TLSOption, ServersTransport
│   ├── traefik-operations.md dashboard, metrics, logs, tracing, troubleshooting, scaling, upgrades
│   ├── traefik-helm-argocd.md helm values, argocd app-of-apps, sync waves, CRD ownership, multi-cluster
│   └── traefik-security.md   tls/mTLS, cert-manager HA, dashboard auth, pod security, snippet allowlist
├── helm/                     ready-to-use values files
│   ├── values-compat.yaml    nginx-replacement / coexistence profile
│   └── values-prod.yaml      production overlay (post-migration, hardened, HPA)
└── tutorial/                 runnable mkdocs course (k3d)
    ├── mkdocs.yml
    ├── docs/                 11 chapters: setup → nginx baseline → traefik → migrate → https → middlewares → canary → ratelimit → decommission → takeaways
    └── artifacts/            all kubectl-appliable yaml + the k3d setup script
```

## start here

- **just want to migrate?** read [traefik-skills/traefik-nginx-migration.md](traefik-skills/traefik-nginx-migration.md) and use [helm/values-compat.yaml](helm/values-compat.yaml).
- **want to learn by doing?** run the [tutorial](tutorial/) — it installs ingress-nginx, then replaces it with traefik on a local k3d cluster, end to end.
- **looking something up?** the five `traefik-skills/*.md` docs are the reference tables.

## the 60-second version

```bash
helm repo add traefik https://traefik.github.io/charts && helm repo update

# install traefik 3.7.1 next to ingress-nginx; it reads the SAME Ingress objects
helm install traefik traefik/traefik -n traefik --create-namespace \
  --version 40.1.0 -f helm/values-compat.yaml

# prove it serves your existing nginx Ingress, WITHOUT touching dns
TRAEFIK_IP=$(kubectl get svc -n traefik traefik \
  -o go-template='{{ (index .status.loadBalancer.ingress 0).ip }}')
curl -v --resolve app.example.com:443:$TRAEFIK_IP https://app.example.com/

# ...validate, dns cutover, then: preserve the nginx IngressClass, uninstall nginx.
```

## run the course

```bash
cd tutorial
pip install mkdocs-material
mkdocs serve            # browse the guided course at localhost:8000
# or just follow docs/*.md and apply artifacts/ by hand
```

## external references

- nginx → traefik official guide: https://doc.traefik.io/traefik/migrate/nginx-to-traefik/
- migration audit tool: https://github.com/traefik/ingress-nginx-migration
- v3.7 announcement (85+ annotations): https://traefik.io/blog/traefik-proxy-3-7-is-available
- v3.7.1 release: https://github.com/traefik/traefik/releases/tag/v3.7.1
- helm chart: https://github.com/traefik/traefik-helm-chart
