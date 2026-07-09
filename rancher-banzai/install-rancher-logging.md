# installing rancher logging operator (gitops) — hybrid: rancher app + argocd

scope: rancher runs as a **deployment inside k8s** (rancher-managed downstream
clusters). we install the rancher-logging operator + crds via rancher's own app
mechanism, and manage the `clusterflow` / `clusteroutput` log-routing config in
git via argocd. chart source = public `https://charts.rancher.io`.

---

## what you're installing

the rancher logging stack is the banzaicloud/kube-logging **logging operator**:

- **fluent bit** — daemonset, collects logs from every node
- **fluentd** — statefulset, aggregates + routes logs to outputs
- driven by crds: `logging`, `flow`/`clusterflow`, `output`/`clusteroutput`

it ships as **two charts that must stay on the same version**, both in the
`cattle-logging-system` namespace:

| chart | what | repo |
|-------|------|------|
| `rancher-logging-crd` | the crds | `https://charts.rancher.io` |
| `rancher-logging` | the operator (fluentbit + fluentd) | `https://charts.rancher.io` |

---

## the ownership split (why hybrid)

because rancher manages the cluster, two systems *can* install charts. don't let
both own the same release — they fight. split ownership cleanly:

| owns | mechanism | sync-wave intent |
|------|-----------|------------------|
| crds + operator | **rancher app** (cluster explorer ▸ apps, or fleet) | installed first |
| `clusterflow` / `clusteroutput` (the actual routing) | **argocd application** | applied after operator is healthy |

rancher owns the operator (so rancher's logging ui still works); argocd owns the
config (so your log pipelines are reviewed + reconciled in git).

---

## step 1 — install operator + crds via rancher app

### option a: rancher ui (simplest)

1. cluster explorer ▸ **apps** ▸ **charts**
2. select **logging** (rancher provides it from the built-in `rancher-charts` repo)
3. for **rke2 downstream clusters**, set under chart values:
   - `additionalLoggingSources.rke2.enabled: true`
   - `systemdLogPath: /var/log/journal`  (or `/run/log/journal` for in-memory journald)
4. install into `cattle-logging-system` (the ui does this automatically)

rancher installs `rancher-logging-crd` then `rancher-logging` at matching versions.

### option b: helm directly (if you bypass the ui)

```bash
helm repo add rancher-charts https://charts.rancher.io
helm repo update

# crds first — SAME version on both installs
helm install rancher-logging-crd rancher-charts/rancher-logging-crd \
  --namespace cattle-logging-system --create-namespace

helm install rancher-logging rancher-charts/rancher-logging \
  --namespace cattle-logging-system \
  --set additionalLoggingSources.rke2.enabled=true \
  --set systemdLogPath=/var/log/journal
```

> pin the chart version (`--version <x>`) and use the **same** version for both
> charts. version drift between crd and operator is the #1 cause of breakage.

verify:

```bash
kubectl -n cattle-logging-system get pods
# expect: rancher-logging-... (operator), rancher-logging-root-fluentbit-... (ds),
#         rancher-logging-root-fluentd-... (sts)
kubectl get crd | grep logging.banzaicloud.io
```

---

## step 2 — manage log routing in git via argocd

put your `clusterflow` / `clusteroutput` manifests in a git path and point one
argocd application at it. these depend on the crds from step 1, so gate with a
later sync-wave.

### argocd application (config only)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rancher-logging-config
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"   # after operator (rancher already up)
spec:
  project: default
  source:
    repoURL: <your-git-repo>
    targetRevision: HEAD
    path: clusters/<cluster>/logging   # dir holding the CRs below
  destination:
    server: https://kubernetes.default.svc
    namespace: cattle-logging-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - ServerSideApply=true
```

### example clusteroutput + clusterflow (route everything to loki)

```yaml
# clusters/<cluster>/logging/clusteroutput-loki.yaml
apiVersion: logging.banzaicloud.io/v1beta1
kind: ClusterOutput
metadata:
  name: loki
  namespace: cattle-logging-system
spec:
  loki:
    url: http://loki.monitoring.svc:3100
    labels:
      cluster: "<cluster>"
---
# clusters/<cluster>/logging/clusterflow-all.yaml
apiVersion: logging.banzaicloud.io/v1beta1
kind: ClusterFlow
metadata:
  name: all-logs
  namespace: cattle-logging-system   # must equal the operator's controlNamespace
spec:
  match:
    - select: {}                      # all namespaces; narrow with namespaces:[...] or labels
  globalOutputRefs:
    - loki
```

> `clusterflow`/`clusteroutput` must live in the operator's **control namespace**
> (`cattle-logging-system`). namespaced `flow`/`output` live in app namespaces and
> only route that namespace's logs.

---

## pure-argocd alternative (if you ever drop the rancher app)

if instead you want argocd to own *everything* (no rancher app), use **3 apps**,
crds split out, sync-wave ordered:

```
rancher-logging-crd     wave -2   chart=rancher-logging-crd  prune=false ServerSideApply=true
rancher-logging         wave -1   chart=rancher-logging      skipCrds=true ServerSideApply=true
rancher-logging-config  wave  0   your clusterflow/clusteroutput
```

argocd application pulling the chart from the public repo:

```yaml
spec:
  source:
    repoURL: https://charts.rancher.io   # helm repo, not git
    chart: rancher-logging
    targetRevision: <pinned-version>
    helm:
      releaseName: rancher-logging
      skipCrds: true                     # crd app owns the crds
      values: |
        additionalLoggingSources:
          rke2: { enabled: true }
        systemdLogPath: /var/log/journal
```

---

## gotchas (all confirmed from rancher docs + argocd issues)

1. **same version on both charts.** `rancher-logging-crd` and `rancher-logging`
   must match; pin them.
2. **`ServerSideApply=true` for the crds.** rancher-logging crds exceed the
   client-side `last-applied-configuration` annotation limit → permanent
   `OutOfSync` / apply errors without ssa.
3. **`prune: false` on the crd app.** never let a sync delete the crds (it would
   take your flows/outputs with them).
4. **rke2 needs `additionalLoggingSources.rke2.enabled` + `systemdLogPath`** to
   collect node/journald logs. pick `/var/log/journal` (persistent) or
   `/run/log/journal` (in-memory).
5. **don't double-own.** if a rancher app installs the operator, do **not** also
   point an argocd app at the `rancher-logging` chart — pick one owner per release.
6. **control namespace.** cluster-scoped `clusterflow`/`clusteroutput` objects
   must sit in `cattle-logging-system`.

---

## sources

- rancher integration with logging — https://ranchermanager.docs.rancher.com/integrations-in-rancher/logging
- rancher-logging helm chart options — https://ranchermanager.docs.rancher.com/integrations-in-rancher/logging/logging-helm-chart-options
- logging architecture — https://ranchermanager.docs.rancher.com/integrations-in-rancher/logging/logging-architecture
- rancher charts repo (charts.rancher.io) — https://github.com/rancher/charts
- argocd sync options (ServerSideApply) — https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
- argocd crd / sync-wave ordering — https://github.com/argoproj/argo-cd/issues/21079
