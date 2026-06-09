# traefik - replace nginx on azure aks, same public ip, no dns change

replace **ingress-nginx** with **traefik v3.7.1** on **azure aks** where:

- traefik runs in **nginx-compat mode** (`kubernetesIngressNGINX` provider), NOT gateway-api/envoy mode
- existing `Ingress` objects (`ingressClassName: nginx` + `nginx.ingress.kubernetes.io/*` annotations) are **not edited**
- traefik serves on the **same azure public ip** ingress-nginx holds today
- **dns is never touched**

this is the azure-specific companion to [traefik-nginx-migration.md](traefik-nginx-migration.md) (annotation mapping) and [traefik-resources.md](traefik-resources.md) (native CRDs).

> all facts verified against learn.microsoft.com (aks static-ip + load-balancer-standard), kubernetes.io (Service / EndpointSlices), cloud-provider-azure source, and the traefik helm chart. sources at the bottom.

---

## two strategies — pick one

there are exactly two sane ways to get "same azure ip, no dns change". the choice is driven entirely by **one question: can traefik live in the `ingress-nginx` namespace, or must it be in its own namespace?**

| | **strategy A — selector swap** (recommended) | **strategy B — move the public ip** |
|---|---|---|
| idea | keep the existing `ingress-nginx-controller` Service object; repoint its `selector` + `targetPort` at traefik pods | give traefik its own LoadBalancer Service and transfer the azure static ip to it |
| azure LB / ip | **never re-provisioned** — same Service object, so same LB, same ip. only EndpointSlices change | ip is **detached from nginx, re-attached to traefik** — one azure reconcile |
| downtime | seconds (endpoint repopulation) | **~1-5 min gap** (single ip can't be on two Services at once) |
| traefik namespace | **MUST be `ingress-nginx`** (same ns as the Service) | **any namespace** (e.g. `traefik`) |
| requires | nothing special | the ip must be a **user-created Static/Standard** public ip |
| risk | lowest | medium (release/re-attach window) |

> **the namespace rule (hard kubernetes law):** a Service's `spec.selector` only matches pods in the **same namespace as the Service**. there is no cross-namespace selector. so strategy A's elegant "keep the Service, swap the selector" trick **only works if traefik runs in `ingress-nginx`**.

### "but i want traefik in a different namespace"

then **strategy A is off the table** and you use **strategy B** (move the ip). the only way to bridge a Service in namespace A to pods in namespace B is a selectorless Service with manually-managed EndpointSlices pointing at the other namespace's **pod IPs** — and pod IPs churn on every reschedule with nothing auto-reconciling them, so for a live ingress data plane that is **brittle and not recommended**. (`ExternalName` / pointing at another Service's clusterIP **cannot** back an inbound LoadBalancer at all.)

so:

- **want least risk + same ip + don't care about namespace** → strategy A, traefik in `ingress-nginx`.
- **want traefik in its own namespace (`traefik`)** → strategy B, move the ip, accept the short reconcile gap.

both are documented below. strategy A first (it's the recommendation).

---

# strategy A — keep the Service, swap the selector (traefik in `ingress-nginx`)

```
before:  Azure Public IP ─► Service ingress-nginx/ingress-nginx-controller ─► nginx pods   ─► Ingress (class nginx)
cutover: Azure Public IP ─► SAME Service (selector patched) ───────────────► traefik pods  ─► same Ingress
after:   Azure Public IP ─► SAME Service ──────────────────────────────────► traefik pods  ─► same Ingress
```

the Service object never changes identity → azure LB + ip are untouched. you only change `spec.selector` (which pods) and `spec.ports[].targetPort` (which pod port). `port: 80/443` stays so the LB frontend is unchanged.

## phase 0 — backup + inventory (no changes)

```bash
mkdir -p migration && cd migration
kubectl get ingress -A -o yaml                                  > 00-ingress-backup.yaml
kubectl get ingressclass -o yaml                                > 01-ingressclass-backup.yaml
kubectl get svc -n ingress-nginx ingress-nginx-controller -o yaml > 02-nginx-svc-backup.yaml
kubectl get validatingwebhookconfiguration ingress-nginx-admission -o yaml > 05-webhook-backup.yaml 2>/dev/null || true

# the production ip + the service's CURRENT selector/ports/policy — you need these for rollback
NGINX_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "production ip: $NGINX_IP"
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.spec.selector}{"\n"}{.spec.externalTrafficPolicy}{"\n"}'
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports}' | jq

# annotation audit — flag snippets/lua (these need manual Middleware work, won't auto-translate)
kubectl get ingress -A -o json | jq -r '.items[].metadata.annotations // {} | keys[]' \
  | grep '^nginx.ingress.kubernetes.io/' | sort | uniq -c | sort -rn
kubectl get ingress -A -o json | jq -r '.items[] | select(.metadata.annotations // {} | keys[] | test("snippet|lua"))
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

## phase 1 — deploy traefik IN `ingress-nginx`, with NO Service of its own

the traefik chart must **not** create a second azure LB. set `service.enabled: false`. traefik just runs as pods; the kept nginx Service will point at them at cutover.

`values-selector-swap.yaml`:

```yaml
# run traefik in the ingress-nginx namespace, as a DaemonSet, with NO own LoadBalancer.
deployment:
  kind: DaemonSet          # see note on externalTrafficPolicy: Local below
  podLabels:
    ingress-cutover/controller: traefik

# CRITICAL: do NOT create a second azure LoadBalancer Service
service:
  enabled: false

providers:
  kubernetesIngressNGINX:
    enabled: true
    ingressClass: nginx
    controllerClass: k8s.io/ingress-nginx
    # stamp the KEPT nginx Service's LB ip into Ingress .status (external-dns/tooling read it).
    # keep this OFF while nginx still serves (avoids status flapping); turn ON at cutover.
    publishService:
      enabled: false
      pathOverride: ingress-nginx/ingress-nginx-controller
  kubernetesCRD: { enabled: true }   # so you can add native Middleware later
  kubernetesIngress: { enabled: false }
  kubernetesGateway: { enabled: false }

# in-pod entrypoint ports. the kept Service will target these.
ports:
  web:       { port: 8000, expose: { default: false } }
  websecure: { port: 8443, expose: { default: false } }

logs:   { general: { level: INFO }, access: { enabled: true, format: json } }
metrics:{ prometheus: { service: { enabled: true }, serviceMonitor: { enabled: true } } }
```

```bash
helm repo add traefik https://traefik.github.io/charts && helm repo update
helm install traefik traefik/traefik -n ingress-nginx \
  --version 40.1.0 -f values-selector-swap.yaml

kubectl rollout status -n ingress-nginx ds/traefik
kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=traefik --show-labels
```

> **why DaemonSet?** the kept nginx Service almost certainly uses `externalTrafficPolicy: Local` (preserves client source ip). with `Local`, azure's LB only sends traffic to nodes that have a **ready pod**, and a node that receives traffic but has no local pod **drops it**. a DaemonSet guarantees one traefik pod per node → every LB-backend node serves locally. (alternative: a Deployment with topology-spread/anti-affinity pinned to a dedicated ingress node pool that is the sole LB backend — more bookkeeping; DaemonSet is the safe default.)

## phase 2 — validate traefik via port-forward (nginx + ip + dns all untouched)

traefik is already reading your unchanged nginx ingresses. test before touching the Service:

```bash
kubectl port-forward -n ingress-nginx ds/traefik 18080:8000 18443:8443 >/dev/null 2>&1 &
sleep 2

for host in app.example.com api.example.com; do
  echo "== $host =="
  curl -s  -o /dev/null -w "  http  %{http_code}\n" -H "Host: $host" http://127.0.0.1:18080/healthz
  curl -sk -o /dev/null -w "  https %{http_code}\n" --resolve $host:18443:127.0.0.1 https://$host:18443/healthz
done

# every nginx ingress became an enabled router?
curl -s localhost:8080/api/http/routers 2>/dev/null | jq '.[] | select(.status!="enabled") | {name,status}' \
  || kubectl exec -n ingress-nginx ds/traefik -- traefik version
```

test the spicy stuff here: tls/SNI (right cert per host), redirects, rewrite-target, auth annotations, body-size, websockets, grpc, sticky sessions, ip allowlist. fix anything (e.g. `strictValidatePathType` rejecting a nginx-lenient ingress → fix `pathType` or set `providers.kubernetesIngressNGINX.strictValidatePathType: false`) **while nginx still serves production.**

## phase 3 — the cutover (patch the kept Service's selector + targetPort)

this is the migration moment. one patch. azure ip unchanged, dns unchanged.

first, **freeze gitops** on this Service or your next sync reverts the patch (see gitops section). then:

```bash
# point the EXISTING nginx Service at traefik pods, and target traefik's in-pod ports
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type=merge -p '{
  "spec": {
    "selector": {
      "app.kubernetes.io/name": "traefik",
      "app.kubernetes.io/instance": "traefik"
    },
    "ports": [
      { "name": "http",  "port": 80,  "protocol": "TCP", "targetPort": 8000 },
      { "name": "https", "port": 443, "protocol": "TCP", "targetPort": 8443 }
    ]
  }
}'
```

> get traefik's actual pod labels from phase 1 (`--show-labels`) and use those exact key/values in the selector. `port: 80/443` stays (LB frontend unchanged); only `targetPort` moves to `8000/8443`.

verify the swap took, on the **real ip**:

```bash
# endpoints now point at traefik pod IPs
kubectl get endpointslice -n ingress-nginx -l kubernetes.io/service-name=ingress-nginx-controller -o wide
# same ip, now traefik answering
kubectl get svc -n ingress-nginx ingress-nginx-controller -o wide   # EXTERNAL-IP == $NGINX_IP, unchanged
curl -sk -o /dev/null -w "%{http_code}\n" --resolve app.example.com:443:$NGINX_IP https://app.example.com/healthz
```

then flip traefik to write Ingress status (nginx is out of the path now):

```bash
helm upgrade traefik traefik/traefik -n ingress-nginx --version 40.1.0 \
  -f values-selector-swap.yaml \
  --set providers.kubernetesIngressNGINX.publishService.enabled=true
```

## phase 3 rollback (instant — just patch the selector back)

no ip moved, so rollback is one patch back to nginx's original selector/ports (from phase 0):

```bash
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type=merge -p '{
  "spec": {
    "selector": {
      "app.kubernetes.io/name": "ingress-nginx",
      "app.kubernetes.io/instance": "ingress-nginx",
      "app.kubernetes.io/component": "controller"
    },
    "ports": [
      { "name": "http",  "port": 80,  "protocol": "TCP", "targetPort": "http" },
      { "name": "https", "port": 443, "protocol": "TCP", "targetPort": "https" }
    ]
  }
}'
```

(use the exact selector/ports your phase-0 backup captured). nginx pods are still running, so traffic flips straight back. azure ip + dns never moved.

## phase 4 — decommission nginx (after 24-72h soak)

```bash
# 1. scale nginx controller down (keep the Service — traefik is using it now!)
kubectl scale deploy ingress-nginx-controller -n ingress-nginx --replicas=0

# 2. remove the nginx admission webhooks (they'd block Ingress writes)
kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found
kubectl delete mutatingwebhookconfiguration   ingress-nginx-admission --ignore-not-found

# 3. PRESERVE the nginx IngressClass — traefik needs it to keep matching your unedited ingresses
kubectl annotate ingressclass nginx helm.sh/resource-policy=keep --overwrite
#    (or keep a standalone IngressClass manifest in gitops, owned outside the nginx release)

# 4. uninstall the nginx CHART but DO NOT let it delete the Service traefik now uses.
#    cleanest: first detach the Service from the chart (gitops section) so uninstall leaves it.
#    if helm-managed, annotate the Service to survive:
kubectl annotate svc ingress-nginx-controller -n ingress-nginx helm.sh/resource-policy=keep --overwrite
helm uninstall ingress-nginx -n ingress-nginx --keep-history   # Service + IngressClass survive via keep policy

# 5. confirm class + Service + ip survived
kubectl get ingressclass nginx
kubectl get svc -n ingress-nginx ingress-nginx-controller -o wide   # still $NGINX_IP, now traefik
```

> uninstalling the nginx chart is the delicate step in strategy A, because the chart **owns the Service traefik is now using**. the `helm.sh/resource-policy: keep` annotation on the Service (and IngressClass) makes helm leave them. better still: detach the Service from the chart **before** cutover (gitops section) so there's no ownership conflict at all.

---

# strategy B — move the azure public ip (traefik in its own namespace)

use this when traefik must live in `traefik` (or any ns ≠ `ingress-nginx`). the ip is detached from nginx and re-attached to a traefik LoadBalancer Service. **prerequisite: the ip must be a user-created Static/Standard public ip** (auto-created ips get deleted with their Service and can't be moved — see "if the ip is auto-created" below).

### the azure ip facts (exact keys)

| purpose | key | note |
|---|---|---|
| pin Service to a named public ip (**preferred**) | `service.beta.kubernetes.io/azure-pip-name` | binds the exact PIP object; avoids throttling |
| pin by ipv4 (alternative) | `service.beta.kubernetes.io/azure-load-balancer-ipv4` | address lookup |
| ip in a different RG (e.g. `MC_*` node RG) | `service.beta.kubernetes.io/azure-load-balancer-resource-group` | cluster identity needs **Network Contributor** there |

**don't use `spec.loadBalancerIP`** — deprecated upstream since k8s v1.24; use `azure-pip-name`. a single Standard ip attaches to **one** Service frontend at a time → it must be released from nginx before traefik claims it.

### confirm the ip is movable

```bash
NGINX_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
az network public-ip list --query "[?ipAddress=='$NGINX_IP'].{name:name,rg:resourceGroup,sku:sku.name,alloc:publicIPAllocationMethod}" -o table
# want: sku=Standard, alloc=Static. note the name (PIP_NAME) and rg (PIP_RG).
```

### phase 1 — traefik on a TEMPORARY ip, validate (nginx + dns untouched)

`values-azure-stage.yaml`:

```yaml
deployment: { kind: DaemonSet }
providers:
  kubernetesIngressNGINX:
    enabled: true
    controllerClass: k8s.io/ingress-nginx
    publishService: { enabled: false }
  kubernetesCRD: { enabled: true }
  kubernetesIngress: { enabled: false }
ingressClass: { enabled: true, isDefaultClass: false }
service:
  spec:
    type: LoadBalancer
    externalTrafficPolicy: Local
    # NO ip pin yet -> azure hands traefik a throwaway ip for validation
ports:
  web: { exposedPort: 80 }
  websecure: { exposedPort: 443, http: { tls: { enabled: true } } }
```

```bash
helm install traefik traefik/traefik -n traefik --create-namespace --version 40.1.0 -f values-azure-stage.yaml
STAGE_IP=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
# validate every host against $STAGE_IP via --resolve (same as strategy A phase 2). nginx still serves prod.
```

### phase 2 — the single ip move (maintenance window, ~1-5 min gap)

```bash
# 2a. release the prod ip from nginx (strip its pin, or scale+delete its Service)
kubectl annotate svc ingress-nginx-controller -n ingress-nginx \
  service.beta.kubernetes.io/azure-pip-name- \
  service.beta.kubernetes.io/azure-load-balancer-ipv4- 2>/dev/null || true
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type=json \
  -p='[{"op":"remove","path":"/spec/loadBalancerIP"}]' 2>/dev/null || true
# wait until azure detaches it (ipConfiguration -> null)
watch -n5 "az network public-ip show -g <PIP_RG> -n <PIP_NAME> --query 'ipConfiguration.id' -o tsv"

# 2b. claim it on traefik
helm upgrade traefik traefik/traefik -n traefik --version 40.1.0 -f values-azure-stage.yaml \
  --set "service.annotations.service\.beta\.kubernetes\.io/azure-pip-name=<PIP_NAME>" \
  --set "service.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-resource-group=<PIP_RG>" \
  --set providers.kubernetesIngressNGINX.publishService.enabled=true \
  --set ingressClass.isDefaultClass=true
watch -n5 "kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'; echo"
# done when it prints $NGINX_IP. dns unchanged, now traefik answering.
```

### phase 2 rollback — give the ip back to nginx

```bash
helm upgrade traefik traefik/traefik -n traefik --version 40.1.0 -f values-azure-stage.yaml   # drops the pin -> releases ip
# wait for release, then re-pin on nginx:
kubectl annotate svc ingress-nginx-controller -n ingress-nginx \
  service.beta.kubernetes.io/azure-pip-name=<PIP_NAME> \
  service.beta.kubernetes.io/azure-load-balancer-resource-group=<PIP_RG>
kubectl scale deploy ingress-nginx-controller -n ingress-nginx --replicas=2   # if scaled down
```

### phase 4 — decommission nginx (same as strategy A: preserve IngressClass, delete webhooks, uninstall)

### if the ip is auto-created (can't be moved)

if `az network public-ip` shows Dynamic/Basic or nothing, nginx's ip was auto-created and is lifecycle-bound. either:
1. **promote it to Static first**: `az network public-ip update -g <MC_RG> -n <name> --allocation-method Static` (must be Standard SKU) — then strategy B applies. **do this before phase 1** if "never touch dns" is absolute.
2. accept one dns change: bring traefik up on a new static ip, validate, flip dns once (lower TTL to 60s first).

---

## gitops caveat (applies to BOTH strategies, critical)

if `ingress-nginx` is argocd/flux-managed, patching its Service `selector`/`ports` (strategy A) or its ip pin (strategy B) is **drift** — the next sync reverts it and re-points traffic at dead nginx pods. fix it one of two ways:

**preferred — detach the Service from the chart** (one owner, no fight): stop rendering the controller Service from the nginx release (`controller.service.enabled: false`) and manage the kept Service as its own gitops-tracked manifest.

**or — `ignoreDifferences`** so sync stops fighting your patch:

```yaml
ignoreDifferences:
  - group: ""
    kind: Service
    name: ingress-nginx-controller
    namespace: ingress-nginx
    jsonPointers:
      - /spec/selector
      - /spec/ports
```

do this **before** cutover.

---

## one-page summary

```
NAMESPACE QUESTION decides the strategy:
  traefik can live in ingress-nginx  ──►  STRATEGY A (selector swap)   ◄── recommended
  traefik must be in its own ns      ──►  STRATEGY B (move the ip)

STRATEGY A (same Service, swap selector — azure LB/ip never re-provisioned):
  0 backup selector/ports/ip + audit annotations          [no change]
  1 install traefik IN ingress-nginx, service.enabled:false, DaemonSet   [nginx serves prod]
  2 validate via port-forward                              [zero impact]
  3 patch Service selector->traefik, targetPort 80->8000 443->8443       [seconds; ip+dns unchanged]
    rollback = patch selector back to nginx                [instant]
  4 soak, scale nginx to 0, preserve IngressClass+Service, uninstall chart

STRATEGY B (move the static ip — traefik in its own ns; ~1-5 min gap):
  0 confirm ip is user-created Static/Standard
  1 traefik in `traefik` ns on a TEMP ip, validate         [nginx serves prod]
  2 release prod ip from nginx -> claim on traefik (azure-pip-name)      [~1-5 min gap]
    rollback = give ip back to nginx
  4 soak, preserve IngressClass, uninstall nginx

BOTH: freeze gitops on the Service before cutover; keep publishService:false during
coexistence then flip true; preserve the `nginx` IngressClass before uninstalling nginx;
DaemonSet (or pinned node pool) because externalTrafficPolicy: Local drops traffic on
nodes without a ready pod; snippets/lua don't auto-translate -> Middleware first.
```

---

## sources

- kubernetes Service (selector is same-namespace; port vs targetPort; type semantics): https://kubernetes.io/docs/concepts/services-networking/service/
- kubernetes EndpointSlices (selector swap only repopulates endpoints): https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- aks static ip (azure-pip-name, resource-group annotation, ip survives detach, loadBalancerIP deprecation): https://learn.microsoft.com/en-us/azure/aks/static-ip
- aks standard load balancer (Standard SKU, per-Service frontend, BYO-ip ownership): https://learn.microsoft.com/en-us/azure/aks/load-balancer-standard
- cloud-provider-azure annotation constants: https://github.com/kubernetes-sigs/cloud-provider-azure/blob/master/pkg/consts/consts.go
- externalTrafficPolicy Local + HealthCheck NodePort (AKS): https://blog.aks.azure.com/2025/04/04/optimize-aks-traffic-with-externaltrafficpolicy-local
- traefik kubernetesIngressNGINX provider (publishService/pathOverride): https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-ingress-nginx/
- traefik helm chart values (ports 8000/8443, service.enabled): https://github.com/traefik/traefik-helm-chart/blob/master/traefik/values.yaml
- nginx → traefik official migration guide: https://doc.traefik.io/traefik/migrate/nginx-to-traefik/
- argocd ignoreDifferences: https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
