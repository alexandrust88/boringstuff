# traefik as an nginx-ingress replacement

a hands-on course. you'll stand up a local cluster with **ingress-nginx** serving a real app, then deploy **traefik v3.7.1** next to it, have traefik serve the *exact same Ingress objects unchanged*, cut traffic over, and decommission nginx — then learn the native CRD model for the work that comes after.

## why traefik 3.7 specifically

traefik 3.7 ("langres") ships the `kubernetesIngressNGINX` provider as GA: it reads your existing `Ingress` objects (`ingressClassName: nginx`) and translates **85+ `nginx.ingress.kubernetes.io/*` annotations natively** (>90% of real usage). so migrating off ingress-nginx is a **dns cutover, not a manifest rewrite**.

## what you'll do

1. provision k3d, install ingress-nginx, deploy `httpbin` behind an nginx `Ingress`
2. install traefik 3.7.1 with the nginx-compat provider, coexisting with nginx
3. prove traefik serves the same Ingress against its own IP — without touching dns
4. add https via cert-manager
5. translate nginx annotations (rate-limit, cors, ip allowlist, canary) — automatic, then native
6. cut over and uninstall nginx safely (preserving the IngressClass)

## versions

| component | version |
|-----------|---------|
| traefik proxy | `v3.7.1` |
| traefik helm chart | `40.1.0` |
| ingress-nginx | latest (baseline to migrate off) |
| k3d | latest |

## artifacts

all yaml referenced here lives under [`artifacts/`](https://github.com/) next to this course. each chapter applies them with `kubectl apply -f`.

!!! note
    this is a companion to the `traefik-skills/` reference docs (SKILL.md + the five sub-docs). the course is the guided path; the skill docs are the lookup tables.
