# rancher-banzai — logging operator to argocd gitops

migrating the **rancher-logging** operator (= banzai cloud / kube-logging logging
operator: fluent-bit collector + fluentd router, driven by `logging` /
`clusterflow` / `clusteroutput` crds) out of the **rancher ui** and into
**argocd gitops**.

collected here from `vault-stack/.tmp/` so it's all in one place.

## files

| file | what it is |
|------|-----------|
| `migrate-rancher-logging-to-argocd.md` | **the main doc** — adopt the two ui-installed helm releases into argocd without downtime (capture → 3 apps → diff → sync → retire ui ownership) |
| `install-rancher-logging.md` | fresh-install / hybrid alternative (rancher app installs operator, argocd manages flow/output) + pure-argocd 3-app variant |
| `session-summary-rancher-logging-gitops.md` | thread of record: what was asked, decided, and the open blocker |

## current state (2026-07-09)

- two releases already exist in `cattle-logging-system`, installed **by hand via
  the rancher ui**: `rancher-logging-crd` + `rancher-logging`.
- this is a **migration / adoption**, not a fresh install. argocd adopts in place
  (adds tracking metadata, no pod recreation) **only if** declared chart version +
  values exactly match the ui install.
- target = 3 sync-wave-ordered argocd apps:
  - `rancher-logging-crd`   (wave -2, `ServerSideApply=true`, `prune: false`)
  - `rancher-logging`       (wave -1, `skipCrds: true`, values pasted verbatim)
  - `rancher-logging-config`(wave  0, git-managed clusterflow/clusteroutput)
- docs only so far — no repo files changed.

## blocker / next action

stuck at **step 0 (capture live state)**: never identified which kubeconfig holds
`cattle-logging-system` (active kubeconfig pointed at a gke cluster needing
`gcloud auth login`).

next: on the correct cluster, run —

```bash
helm list -n cattle-logging-system
helm get metadata rancher-logging      -n cattle-logging-system   # exact version
helm get metadata rancher-logging-crd  -n cattle-logging-system
helm get values   rancher-logging     -n cattle-logging-system -a > rancher-logging.values.yaml
helm get values   rancher-logging-crd -n cattle-logging-system -a > rancher-logging-crd.values.yaml
kubectl -n cattle-logging-system get logging,clusterflow,clusteroutput,flow,output -o yaml > logging-crs.yaml
```

then fill the real versions + verbatim values into the three app manifests in
`migrate-rancher-logging-to-argocd.md`, `argocd app diff` (must be metadata-only),
then sync crd → operator → config.

## open decisions

1. which git repo/path owns the 3 argocd applications + the clusterflow/output crs.
2. is rancher/fleet actively reconciling these releases (→ need the step-4 "retire
   ui ownership" step) or was it a one-off ui click (→ leave dormant fleet alone).
