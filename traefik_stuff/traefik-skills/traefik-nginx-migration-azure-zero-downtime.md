# traefik - replace nginx on azure aks with ZERO downtime, same ip, no dns change (v2)

> **v2 of [traefik-nginx-migration-azure-ip-reuse.md](traefik-nginx-migration-azure-ip-reuse.md).** that doc's "selector swap" had a seconds-level switchover and an instant-but-binary cutover. this version achieves **true zero downtime with a gradual canary through the same azure ip**, using one verified trick: the existing nginx Service selects **both** controllers at once via kubernetes **named targetPorts** (resolved per-pod). every load-bearing claim below was verified against k8s docs, the traefik chart 40.1.0 rendered with `helm template`, and traefik v3.7.1 source. sources at the bottom.

goal:

- replace **ingress-nginx** with **traefik v3.7.1** (chart **40.1.0+**) on **azure aks**
- traefik in **nginx-compat mode** (`kubernetesIngressNGINX` provider) — `Ingress` objects with `ingressClassName: nginx` stay **byte-for-byte unchanged**
- **same azure public ip, same azure LB, dns never touched**
- **zero downtime**: at no point is there a moment with no ready backend; cutover is a gradual canary, rollback is instant at every step

---

## the trick that makes zero downtime possible

three verified kubernetes/traefik facts compose into the design:

1. **named targetPorts resolve per-pod.** the ingress-nginx Service already uses `targetPort: http` / `targetPort: https` (names, not numbers). kubernetes resolves a named targetPort against **each backing pod individually** — official docs: *"This works even if there is a mixture of Pods in the Service using a single configured name, with the same network protocol available via different port numbers."* so one Service can send `http` to port 80 on nginx pods and port 8000 on traefik pods **simultaneously**.

2. **a Service selector is just labels.** nothing ties it to one workload. give nginx pods and traefik pods a shared label, point the Service selector at that label, and the EndpointSlices contain both pod sets. traffic splits across all ready endpoints (per-connection); the split ratio ≈ ready-pod-count ratio.

3. **the traefik chart can name its container ports `http`/`https`.** the chart's `ports:` map key becomes the entrypoint name AND the container port name (verified in `_podtemplate.tpl`). nulling `web`/`websecure` and defining `http`/`https` keys renders container ports literally named `http`(8000) and `https`(8443) — exactly what the nginx Service's named targetPorts need. **one mandatory companion setting:** the nginx-compat provider pins routers to entrypoints `web`/`websecure` by default, so you must set `providers.kubernetesIngressNGINX.httpEntryPoint: "http"` and `httpsEntryPoint: "https"` or every router lands on a nonexistent entrypoint and is dropped.

result:

```
                                   Azure Public IP (never moves)
                                            |
                       Service ingress-nginx/ingress-nginx-controller   (never recreated)
                       port 80  -> targetPort "http"   (NAMED)
                       port 443 -> targetPort "https"  (NAMED)
                       selector: { edge: shared }      (the one patch)
                              /                  \
                 nginx pods (label edge=shared)   traefik pods (label edge=shared)
                 "http"  -> containerPort 80      "http"  -> containerPort 8000
                 "https" -> containerPort 443     "https" -> containerPort 8443
                              \                  /
                        same unchanged Ingress objects (class nginx)
```

azure sees nothing: the LB backend pool is **nodes**, the frontend/ip/probes derive from `spec.ports[].port` + `type` + `externalTrafficPolicy` + `azure-*` annotations — none of which change. selector and named-targetPort resolution are consumed purely by kube-proxy (or cilium) on the nodes.

why this is zero-downtime at every transition:

- when the selector flips to `edge: shared`, **nginx pods match both the old and the new selector** — they are never removed from the endpoints. traefik pods are only *added* (and only once Ready; EndpointSlices never include unready pods).
- canary = scaling nginx replicas down while the traefik DaemonSet covers every node. each step only *removes some* nginx endpoints; established TCP connections are conntrack-pinned and keep flowing to their pod until they close naturally — endpoint removal only redirects **new** connections (verified for iptables, ipvs, and cilium dataplanes).
- with `externalTrafficPolicy: Local`, the azure health probe stays green on every node throughout, because the traefik DaemonSet guarantees a local ready endpoint on every node from phase 2 onward.

---

## constraints, stated honestly

| constraint | why |
|---|---|
| traefik must run in the **`ingress-nginx` namespace** | a Service selector only matches pods in its own namespace — hard k8s rule. different namespace ⇒ this design is impossible; use the ip-move strategy in the [v1 doc](traefik-nginx-migration-azure-ip-reuse.md) (strategy B, ~1-5 min gap) |
| adding the shared label to nginx pods triggers **one rolling restart of nginx** | `controller.podLabels` changes the pod template (selector untouched — it's immutable and `podLabels` never reaches `matchLabels`). a normal rolling update, not downtime — but schedule it |
| canary percentages are **approximate** | with `externalTrafficPolicy: Local`, azure spreads per-node and kube-proxy picks among that node's *local* endpoints; the global ratio is the average of per-node ratios. do **not** flip the policy mid-migration to fix this — changing `externalTrafficPolicy` rewrites the azure probe model and is the one adjacent change that *does* touch the LB |
| long-lived connections to nginx (websockets) end when nginx pods finally terminate | inherent to removing nginx at all; nginx drains gracefully within `terminationGracePeriodSeconds`. everything short-lived completes untouched |
| gitops will fight the selector patch | freeze argocd/flux on the Service (or detach it from the nginx chart) **before** patching — see the gitops section |

---

## full worked example

concrete environment used throughout (replace with yours):

| thing | value |
|---|---|
| aks cluster | `aks-prod-weu` in rg `rg-prod-weu` |
| node rg | `MC_rg-prod-weu_aks-prod-weu_westeurope` |
| production ip | `20.103.42.7` (static, Standard) |
| nginx release/ns | `ingress-nginx` / `ingress-nginx` |
| traefik chart | `40.1.0` (appVersion `v3.7.1`) |
| example host | `app.example.com` (dns A → `20.103.42.7`, never changed) |

an example of the kind of `Ingress` that must keep working unchanged:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app
  namespace: app
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: "20m"
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/cors-allow-origin: "https://ui.example.com"
    nginx.ingress.kubernetes.io/limit-rps: "50"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [app.example.com]
      secretName: app-tls
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: app, port: { number: 80 } }
```

### phase 0 — inventory + backups (read-only)

```bash
mkdir -p migration && cd migration

# backups you will need for rollback
kubectl get svc -n ingress-nginx ingress-nginx-controller -o yaml > 00-nginx-svc.yaml
kubectl get ingress -A -o yaml                                    > 01-ingresses.yaml
kubectl get ingressclass -o yaml                                  > 02-ingressclasses.yaml

# the facts that drive the plan
NGINX_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "ip: $NGINX_IP"                                              # 20.103.42.7
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='selector={.spec.selector}{"\n"}policy={.spec.externalTrafficPolicy}{"\n"}ports={.spec.ports}{"\n"}'
```

expected (chart defaults — **verify yours match**, the named targetPorts are the load-bearing fact):

```text
selector={"app.kubernetes.io/component":"controller","app.kubernetes.io/instance":"ingress-nginx","app.kubernetes.io/name":"ingress-nginx"}
policy=Local
ports=[{"name":"http","port":80,"protocol":"TCP","targetPort":"http"},{"name":"https","port":443,"protocol":"TCP","targetPort":"https"}]
```

> if your Service uses **numeric** targetPorts (80/443) instead of named ones, patch it to the named form first — it's a no-op for nginx (nginx container ports 80/443 are named `http`/`https`), and it enables the per-pod resolution this design needs:
>
> ```bash
> kubectl patch svc ingress-nginx-controller -n ingress-nginx --type=json -p='[
>   {"op":"replace","path":"/spec/ports/0/targetPort","value":"http"},
>   {"op":"replace","path":"/spec/ports/1/targetPort","value":"https"}]'
> ```

annotation audit (snippets/lua need manual `Middleware` work before cutover — see the [base migration doc](traefik-nginx-migration.md)):

```bash
kubectl get ingress -A -o json | jq -r '.items[].metadata.annotations // {} | keys[]' \
  | grep '^nginx.ingress.kubernetes.io/' | sort | uniq -c | sort -rn
kubectl get ingress -A -o json | jq -r '.items[] | select(.metadata.annotations // {} | keys[] | test("snippet|lua"))
  | "\(.metadata.namespace)/\(.metadata.name)"'
```

### phase 1 — give nginx pods the shared label (one rolling restart, zero downtime)

```bash
helm upgrade ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --reuse-values \
  --set controller.podLabels.edge=shared

kubectl rollout status -n ingress-nginx deploy/ingress-nginx-controller
kubectl get pods -n ingress-nginx -l edge=shared    # nginx pods now carry edge=shared
```

safe because `controller.podLabels` only adds **pod template** labels — the Deployment's immutable `spec.selector.matchLabels` is untouched (verified in the chart template). it is a normal rolling update; the Service still selects by the original nginx labels, which every pod still has.

> gitops-managed nginx? make this values change through gitops, not `--reuse-values`.

### phase 2 — deploy traefik into `ingress-nginx` with http/https-named ports (zero impact)

the values file (full copy at [helm/values-azure-shared-service.yaml](../helm/values-azure-shared-service.yaml)) — every non-obvious line is verified against chart 40.1.0:

```yaml
deployment:
  kind: DaemonSet              # externalTrafficPolicy: Local needs a ready local endpoint per node
  podLabels:
    edge: shared               # joins the same Service as nginx

service:
  enabled: false               # CRITICAL: no second azure LB — the kept nginx Service fronts traefik

# rename entrypoints so CONTAINER PORT NAMES are exactly http/https
# (map key = entrypoint name = container port name; verified in _podtemplate.tpl)
ports:
  web: null                    # remove defaults (supported; schema accepts null)
  websecure: null
  http:
    port: 8000                 # in-pod port; the Service's named targetPort "http" resolves here
  https:
    port: 8443
    http:
      tls:
        enabled: true          # entrypoint-level tls (note: nested under http.tls)

providers:
  kubernetesIngressNGINX:
    enabled: true
    ingressClass: nginx
    controllerClass: k8s.io/ingress-nginx
    # MANDATORY with renamed ports: provider defaults pin routers to web/websecure;
    # without these overrides every router targets a nonexistent entrypoint and is dropped.
    httpEntryPoint: "http"
    httpsEntryPoint: "https"
    publishService:
      enabled: false           # nginx still owns Ingress .status during coexistence
      pathOverride: ingress-nginx/ingress-nginx-controller
  kubernetesCRD:
    enabled: true              # native Middleware available for snippet re-expression
  kubernetesIngress:
    enabled: false
  kubernetesGateway:
    enabled: false

ingressClass:
  enabled: false               # pure nginx-class operation; no traefik class needed

logs:
  general: { level: INFO }
  access:  { enabled: true, format: json }
metrics:
  prometheus:
    service: { enabled: true }
    serviceMonitor: { enabled: true }
```

```bash
helm repo add traefik https://traefik.github.io/charts && helm repo update
helm install traefik traefik/traefik -n ingress-nginx \
  --version 40.1.0 -f values-azure-shared-service.yaml

kubectl rollout status -n ingress-nginx ds/traefik
```

verify the two facts the design depends on:

```bash
# (1) container ports are NAMED http/https
kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=traefik \
  -o jsonpath='{.items[0].spec.containers[0].ports}' | jq
# expect: [{"containerPort":8000,"name":"http",...},{"containerPort":8443,"name":"https",...},{"containerPort":8080,"name":"traefik",...}]

# (2) every nginx Ingress became an ENABLED router, pinned to entrypoints http/https
kubectl port-forward -n ingress-nginx ds/traefik 8080:8080 >/dev/null 2>&1 & sleep 2
curl -s localhost:8080/api/http/routers | jq '.[] | {name, rule, status, entryPoints}'
curl -s localhost:8080/api/http/routers | jq '[.[] | select(.status!="enabled")] | length'   # want: 0
```

functional validation via port-forward, with the real Host header — nginx still serves all production traffic, so this is zero-risk:

```bash
kubectl port-forward -n ingress-nginx ds/traefik 18080:8000 18443:8443 >/dev/null 2>&1 & sleep 2
curl -s  -o /dev/null -w "http  %{http_code}\n" -H "Host: app.example.com" http://127.0.0.1:18080/
curl -sk -o /dev/null -w "https %{http_code}\n" --resolve app.example.com:18443:127.0.0.1 https://app.example.com:18443/
# check the annotations translated: cors header present? body-size enforced (413 on >20m)? redirect on http?
curl -is -H "Host: app.example.com" -H "Origin: https://ui.example.com" http://127.0.0.1:18080/ | grep -i access-control
```

> a router shows `disabled`? most common cause on 3.7: `strictValidatePathType` (default true) rejecting a `pathType` nginx tolerated. fix the Ingress, or set `providers.kubernetesIngressNGINX.strictValidatePathType: false`.

### phase 3 — freeze gitops on the Service, then join traefik to it (the one patch — still zero downtime)

freeze first (otherwise the next sync reverts the selector into the original nginx-only labels):

```yaml
# argocd Application that owns ingress-nginx — add BEFORE patching:
ignoreDifferences:
  - group: ""
    kind: Service
    name: ingress-nginx-controller
    namespace: ingress-nginx
    jsonPointers:
      - /spec/selector
```

now the patch. **must be a json `replace` op** — a merge patch (`--type=merge` or strategic) *merges* map keys, leaving the old nginx labels in the selector, and the combined selector would match nothing:

```bash
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type=json \
  -p='[{"op":"replace","path":"/spec/selector","value":{"edge":"shared"}}]'
```

why nothing blips at this instant:

- old selector matched nginx pods; new selector matches nginx pods **and** traefik pods. nginx endpoints are in both sets → never removed. traefik endpoints are added.
- `spec.ports` unchanged → azure LB frontend/probes untouched. named targetPort `http` now resolves to 80 on nginx pods and 8000 on traefik pods, per-pod.

verify both controllers are live behind the one ip:

```bash
# endpoints: nginx pod IPs (port 80/443) AND traefik pod IPs (port 8000/8443)
kubectl get endpointslice -n ingress-nginx -l kubernetes.io/service-name=ingress-nginx-controller \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\t"}{.targetRef.name}{"\n"}{end}'

# hit production a few times; responses now come from a mix (Server header / access logs tell them apart)
for i in $(seq 1 10); do
  curl -sk -o /dev/null -w "%{http_code} " --resolve app.example.com:443:$NGINX_IP https://app.example.com/
done; echo
kubectl logs -n ingress-nginx ds/traefik --since=1m | jq -c 'select(.RequestHost=="app.example.com") | {code:.DownstreamStatus, router:.RouterName}' | tail
```

**instant rollback at this stage** — one json patch back (nginx pods never stopped serving):

```bash
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type=json \
  -p='[{"op":"replace","path":"/spec/selector","value":{
    "app.kubernetes.io/name":"ingress-nginx",
    "app.kubernetes.io/instance":"ingress-nginx",
    "app.kubernetes.io/component":"controller"}}]'
```

### phase 4 — canary: shift weight by scaling nginx down (each step reversible, zero downtime)

the split ratio ≈ ready-pod ratio (per-node with `Local` — approximate, see constraints). traefik (DaemonSet) covers every node; reduce nginx replicas stepwise:

```bash
# example: 3 nginx replicas + traefik on 5 nodes ≈ 35-40% nginx / 60-65% traefik already
kubectl scale deploy ingress-nginx-controller -n ingress-nginx --replicas=2   # observe
kubectl scale deploy ingress-nginx-controller -n ingress-nginx --replicas=1   # observe
```

each scale-down only removes *some* nginx endpoints; established connections to a removed pod keep flowing until they close (conntrack pins established TCP flows; endpoint changes only steer **new** connections — verified for iptables/ipvs/cilium). between steps, watch:

```bash
# error budget: traefik-served 5xx vs nginx baseline
kubectl logs -n ingress-nginx ds/traefik --since=10m | jq -c 'select(.DownstreamStatus>=500)' | wc -l
# latency p99 via metrics (or your prometheus):
curl -s localhost:8080/metrics | grep -E 'traefik_service_request_duration_seconds'
# azure LB node health stays green (Local policy): all nodes have a local traefik endpoint
kubectl get pods -n ingress-nginx -o wide | grep traefik
```

gate to advance: traefik 5xx delta < 0.1% over nginx baseline, p99 stable, no new error classes. rollback at any step = scale nginx back up (pods rejoin the endpoints as they become Ready) or the phase-3 selector revert.

### phase 5 — complete: nginx leaves the data plane (still zero downtime)

```bash
kubectl scale deploy ingress-nginx-controller -n ingress-nginx --replicas=0
```

nginx pods terminate gracefully (`terminationGracePeriodSeconds`, nginx drains in-flight requests); they leave the endpoints as they go Unready **before** the process exits, so new connections already steer to traefik. the Service, ip, dns: untouched. traefik is now the sole backend.

flip traefik to own `Ingress` `.status` (tooling like external-dns reads it; the value it writes is the same Service ip nginx wrote, via `pathOverride`):

```bash
helm upgrade traefik traefik/traefik -n ingress-nginx --version 40.1.0 \
  -f values-azure-shared-service.yaml \
  --set providers.kubernetesIngressNGINX.publishService.enabled=true
```

soak 24-72h. rollback during soak = `kubectl scale deploy ingress-nginx-controller --replicas=2` — the pods rejoin the shared selector automatically.

### phase 6 — decommission nginx (after soak)

the nginx chart **owns the Service traefik now fronts through** and the `nginx` IngressClass traefik matches on. protect both before uninstalling:

```bash
# 1. pin the Service + IngressClass so helm uninstall leaves them
kubectl annotate svc ingress-nginx-controller -n ingress-nginx helm.sh/resource-policy=keep --overwrite
kubectl annotate ingressclass nginx helm.sh/resource-policy=keep --overwrite
#    (gitops: better — move both into their own platform-owned manifests/Application first)

# 2. remove the admission webhooks (they block all Ingress writes once the controller is gone)
kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found
kubectl delete mutatingwebhookconfiguration   ingress-nginx-admission --ignore-not-found

# 3. uninstall the chart; verify the survivors
helm uninstall ingress-nginx -n ingress-nginx
kubectl get svc -n ingress-nginx ingress-nginx-controller -o wide   # still 20.103.42.7, fronting traefik
kubectl get ingressclass nginx                                      # still exists; traefik matches on it

# 4. final state check via real dns (never changed)
curl -sk -o /dev/null -w "%{http_code}\n" https://app.example.com/
```

done: same azure ip, same Service, dns untouched, `Ingress` objects byte-for-byte unchanged, zero downtime end to end.

---

## the whole thing on one page

```text
phase 0  backup svc/ingresses; CONFIRM Service uses NAMED targetPorts http/https     [read-only]
phase 1  nginx: controller.podLabels.edge=shared   (one rolling restart)             [zero downtime]
phase 2  traefik DaemonSet in ingress-nginx ns:
           service.enabled=false, ports renamed web/websecure -> http/https,
           httpEntryPoint/httpsEntryPoint overridden, publishService=false
         validate via port-forward against real Host headers                         [zero impact]
phase 3  freeze gitops on the Service, then ONE json-replace patch:
           selector -> {edge: shared}   (nginx stays in endpoints, traefik joins)    [zero downtime]
phase 4  canary by scaling nginx replicas down; conntrack keeps established flows    [each step reversible]
phase 5  nginx replicas -> 0 (graceful drain); publishService -> true                [zero downtime]
phase 6  pin Service+IngressClass (resource-policy: keep), delete webhooks,
         uninstall nginx chart                                                       [traefik sole controller]

rollback at ANY phase: selector json-replace back to nginx labels, or scale nginx up.
the azure LB, public ip, and dns are never touched at any phase.
```

---

## verified-gotchas checklist

- [ ] Service targetPorts are **named** (`http`/`https`) — convert from numeric first if needed (no-op for nginx)
- [ ] traefik in the **same namespace** as the Service (`ingress-nginx`) — selector cannot cross namespaces
- [ ] traefik chart: `ports.web: null`, `ports.websecure: null`, keys `http`/`https` (tls under `http.tls`, not top-level)
- [ ] **`httpEntryPoint: "http"` + `httpsEntryPoint: "https"`** set on the provider — mandatory with renamed ports (requires appVersion ≥ 3.7.0; chart enforces)
- [ ] `service.enabled: false` on the traefik chart — no second azure LB
- [ ] selector patch uses **json `replace`** — merge/strategic patches merge map keys and yield a selector matching nothing
- [ ] do **not** change `externalTrafficPolicy` or `spec.ports[].port` mid-migration — those are the fields that reconcile the azure LB/probes
- [ ] traefik as **DaemonSet** so every node has a local ready endpoint under `Local` policy (probe stays green; no per-node blackholes)
- [ ] gitops `ignoreDifferences` on `/spec/selector` (or detach the Service) **before** phase 3
- [ ] chart probes still target internal `:8080 /ping` after the rename (verified) — don't null `ports.traefik` without `deployment.healthchecksPort`
- [ ] snippets/lua re-expressed as `Middleware` before phase 4 ramps
- [ ] `helm.sh/resource-policy: keep` on Service + IngressClass before `helm uninstall ingress-nginx`
- [ ] aks dataplane note: on azure-cni-powered-by-cilium clusters there is no kube-proxy; the conntrack/endpoint semantics hold the same way via cilium's BPF maps

---

## sources (all claims verified against these)

- kubernetes Service — named targetPort resolved per-pod, mixed pods: https://kubernetes.io/docs/concepts/services-networking/service/
- kubernetes virtual IPs / kube-proxy — endpoint selection, Local policy: https://kubernetes.io/docs/reference/networking/virtual-ips/
- conntrack pins established flows (endpoint removal only affects new connections): https://kubernetes.io/blog/2019/03/29/kube-proxy-subtleties-debugging-an-intermittent-connection-reset/
- deployment selector immutable; podLabels are template-only: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- ingress-nginx chart — named targetPorts, containerPort names, podLabels: https://github.com/kubernetes/ingress-nginx/blob/main/charts/ingress-nginx/values.yaml
- traefik chart 40.1.0 — port key = entrypoint name = container port name (`_podtemplate.tpl`), `ports` schema, EXAMPLES: https://github.com/traefik/traefik-helm-chart/tree/v40.1.0
- traefik v3.7.1 source — nginx provider entrypoint pinning (`httpEntryPoint`/`httpsEntryPoint`): https://github.com/traefik/traefik/blob/v3.7.1/pkg/provider/kubernetes/ingress-nginx/kubernetes.go
- kubernetesIngressNGINX provider reference: https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-ingress-nginx/
- cloud-provider-azure — LB built from ports/type/policy/annotations; backend pool = nodes: https://cloud-provider-azure.sigs.k8s.io/topics/loadbalancer/
- aks Local policy + HealthCheck NodePort: https://blog.aks.azure.com/2025/04/04/optimize-aks-traffic-with-externaltrafficpolicy-local
- argocd ignoreDifferences: https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
