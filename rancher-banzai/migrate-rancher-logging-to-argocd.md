# migrating rancher-logging from rancher-ui to full argocd gitops

starting state: `rancher-logging-crd` and `rancher-logging` are **already
installed in `cattle-logging-system`**, done **manually via the rancher ui**
(helm releases exist; rancher/fleet "owns" them).

goal: bring **everything** under argocd — crds + operator + flow/output config —
so nothing is clicked in the ui anymore.

this is a **migration / adoption**, not a fresh install. argocd will *adopt* the
existing resources in place (it just adds tracking metadata); pods are not
recreated as long as the chart + values you declare match what's already
deployed.

---

## the one hard rule

**stop installing/upgrading it from the rancher ui.** once argocd owns the
release, the ui (fleet) and argocd are two owners of the same release and will
fight. after migration, all changes go through git.

> note: rancher installs these from its built-in `rancher-charts` repo (mirror of
> `https://charts.rancher.io`). when argocd pulls the same chart name+version from
> `https://charts.rancher.io`, the rendered manifests match, so adoption is clean.

---

## step 0 — capture the live state (do this FIRST, before touching anything)

set the kubeconfig for the cluster that has the releases, then:

```bash
# exact chart versions + who deployed (must reuse these versions in argocd)
helm list -n cattle-logging-system
helm get metadata rancher-logging      -n cattle-logging-system
helm get metadata rancher-logging-crd  -n cattle-logging-system

# the EXACT values the ui installed with — argocd must match these
helm get values rancher-logging     -n cattle-logging-system -a > rancher-logging.values.yaml
helm get values rancher-logging-crd -n cattle-logging-system -a > rancher-logging-crd.values.yaml

# current crs (so you know what config to move into git)
kubectl -n cattle-logging-system get logging,clusterflow,clusteroutput,flow,output -o yaml > logging-crs.yaml
```

keep `rancher-logging.values.yaml` — you paste it verbatim into the argocd app so
the render is identical (no diff, no pod churn).

---

## step 1 — decide adoption strategy

two safe options. pick one.

### option a — argocd "soft" adoption (recommended, zero downtime)

argocd takes over the existing resources in place. the old helm release secret
(`sh.helm.release.v1.rancher-logging.*`) becomes irrelevant; argocd tracks via its
own annotations. resources keep running.

requirements that make this non-destructive:
- argocd app `chart` + `targetRevision` == the versions from `helm get metadata`
- argocd app `helm.values` == output of `helm get values ... -a`
- sync with **`ServerSideApply=true`** + **diff first**, never replace

### option b — clean cutover (uninstall release, re-adopt)

`helm uninstall --keep-history=false` would delete the workloads — **don't** do
that for the operator (downtime + crd risk). only consider this if the ui release
is in a broken state. option a is the right default.

---

## step 2 — the three argocd applications

reproduce the rancher install as 3 git-owned apps, crds split out, sync-wave
ordered. release names **must match** the existing releases so adoption is clean.

### 2a. crds — wave -2

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rancher-logging-crd
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  project: default
  source:
    repoURL: https://charts.rancher.io
    chart: rancher-logging-crd
    targetRevision: <version-from-helm-metadata>   # MUST match installed
    helm:
      releaseName: rancher-logging-crd             # MUST match installed release
  destination:
    server: https://kubernetes.default.svc
    namespace: cattle-logging-system
  syncPolicy:
    automated: { prune: false, selfHeal: true }    # never prune crds
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
```

### 2b. operator — wave -1

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rancher-logging
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: default
  source:
    repoURL: https://charts.rancher.io
    chart: rancher-logging
    targetRevision: <version-from-helm-metadata>   # SAME version as crd
    helm:
      releaseName: rancher-logging                 # MUST match installed release
      skipCrds: true                               # crd app owns the crds
      values: |
        # >>> paste rancher-logging.values.yaml here VERBATIM <<<
        # (output of: helm get values rancher-logging -n cattle-logging-system -a)
  destination:
    server: https://kubernetes.default.svc
    namespace: cattle-logging-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
```

### 2c. config (flow/output) — wave 0

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rancher-logging-config
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: <your-git-repo>
    targetRevision: HEAD
    path: clusters/<cluster>/logging   # holds your clusterflow/clusteroutput yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: cattle-logging-system
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - ServerSideApply=true
```

move the crs from `logging-crs.yaml` (step 0) into that git path. example:

```yaml
apiVersion: logging.banzaicloud.io/v1beta1
kind: ClusterOutput
metadata:
  name: loki
  namespace: cattle-logging-system
spec:
  loki:
    url: http://loki.monitoring.svc:3100
---
apiVersion: logging.banzaicloud.io/v1beta1
kind: ClusterFlow
metadata:
  name: all-logs
  namespace: cattle-logging-system
spec:
  match: [{ select: {} }]
  globalOutputRefs: [loki]
```

---

## step 3 — adopt safely (diff BEFORE sync)

apply the app manifests with **automated sync OFF first**, or create them and
inspect the diff before the first sync:

```bash
kubectl apply -f rancher-logging-crd.application.yaml
kubectl apply -f rancher-logging.application.yaml

# inspect what argocd WOULD change — must be only metadata/annotations, no
# delete/recreate of deployments/daemonsets/statefulsets
argocd app diff rancher-logging
argocd app diff rancher-logging-crd
```

expected clean diff: argocd adds its tracking label/annotation
(`app.kubernetes.io/instance` / `argocd.argoproj.io/tracking-id`). it should NOT
show the fluentd statefulset or fluentbit daemonset being replaced.

if the diff shows real spec changes, your `values:` or `targetRevision` doesn't
match the ui install — fix it to match `helm get values` / `helm get metadata`
before syncing.

then sync (crd app first):

```bash
argocd app sync rancher-logging-crd
argocd app sync rancher-logging
argocd app sync rancher-logging-config
```

verify nothing churned:

```bash
kubectl -n cattle-logging-system get pods       # AGE should be unchanged
kubectl -n cattle-logging-system get logging,clusterflow,clusteroutput
```

---

## step 4 — retire ui ownership

once argocd shows all three apps `Synced`/`Healthy`:

1. in rancher ui, **do not** upgrade/manage the logging app there anymore.
2. (optional, only if rancher/fleet keeps reconciling and conflicting) detach the
   rancher app from management — leave the workloads, just stop fleet owning them.
   in the rancher ui that's the logging app ▸ delete the *app/fleet binding* while
   keeping resources; verify argocd still owns them via `kubectl get deploy
   rancher-logging -n cattle-logging-system -o jsonpath='{.metadata.labels}'`.

> if you're unsure whether fleet still owns it, leave it — the danger is only if
> fleet actively re-syncs. if it doesn't touch the release, argocd + dormant fleet
> coexist fine. test by changing a value in git and confirming argocd wins.

---

## gotchas (confirmed: rancher docs + argocd adoption guides)

1. **versions must match the ui install** (`helm get metadata`), and crd+operator
   must share the same version. otherwise the first sync is an upgrade, not an
   adoption.
2. **values must match** (`helm get values -a`) — paste verbatim. a values diff =
   pod churn on first sync.
3. **`ServerSideApply=true`** — rancher-logging crds exceed the client-side
   `last-applied-configuration` annotation limit → permanent `OutOfSync` without
   ssa.
4. **`prune: false` on the crd app** — a stray sync must never delete crds (would
   take flows/outputs with them).
5. **single owner** — after migration, stop using the rancher ui for this app.
6. **diff before sync** — adoption is only safe if the diff is metadata-only.
7. **rke2 sources** — if the ui install had
   `additionalLoggingSources.rke2.enabled` + `systemdLogPath`, those will be in
   `helm get values -a`; keep them.

---

## sources

- onboard existing helm release into argocd — https://www.aviator.co/blog/how-to-onboard-an-existing-helm-application-in-argocd/
- argocd helm + releaseName — https://argo-cd.readthedocs.io/en/stable/user-guide/helm/
- argocd sync options (ServerSideApply) — https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
- rancher logging chart options — https://ranchermanager.docs.rancher.com/integrations-in-rancher/logging/logging-helm-chart-options
- rancher charts repo — https://github.com/rancher/charts
