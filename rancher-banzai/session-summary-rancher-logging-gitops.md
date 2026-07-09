# session summary — rancher-logging operator under gitops

date: 2026-07-09
topic: managing the rancher logging operator (`cattle-logging-system`) in gitops
style via argocd — from research to a migration plan, since the operator was
installed manually via the rancher ui.

---

## request evolution (what the user actually asked, in order)

1. "find conversation about managing rancher + logging operator in gitops style /
   cattle addon logging operator" — searched claude-mem, **not in memory**.
2. "build it fresh — argocd app/appset deploying rancher-logging into
   cattle-logging-system, with clusterflow/clusteroutput in git; chart of rancher
   using addon."
3. "how do i manage a rancher helm chart install via argocd?" + "search internet
   first."
4. clarified: **rancher runs as a deployment in k8s** (rancher-managed downstream
   cluster), not rke2-on-host → "addon" = rancher app/fleet, not host manifests.
5. answers to scoping questions: hybrid (rancher app + argocd), **public
   charts.rancher.io**, "just need docs."
6. "in cattle-system i already have rancher-logging + rancher-logging-crd
   installed (helm list shows them)" → **installed via the rancher ui**.
7. final ask: manage **all of it** under gitops (crds + operator + config), not
   just the flow/output layer.

---

## memory search result

no prior conversation on rancher/cattle logging operator exists in claude-mem for
the vault-stack project. closest hits were rke2 `addons.yaml` (secrets/infoblox,
not logging), nks addon rollout (external-secrets), and vault-audit loki query
playbooks under `ops/loki/` + `ops/vault-audit-query/`. this session is the first
on this topic.

also discovered via grep: an existing kustomize logging component pattern at
`vault-crossplane/.tmp/repos/eso-onboarding-repos/infra-common-deployments/
components/monitoring/logging/` (base + per-env overlays) — potential convention
reference, not yet used.

---

## key facts established (from web research + rancher docs)

- rancher-logging = banzaicloud/kube-logging **logging operator**: fluent bit
  (daemonset collector) + fluentd (statefulset router), driven by crds
  `logging`, `flow`/`clusterflow`, `output`/`clusteroutput`.
- ships as **two charts, same version, same namespace `cattle-logging-system`**:
  `rancher-logging-crd` + `rancher-logging`. repo: `https://charts.rancher.io`.
- helm 3 doesn't upgrade crds and argocd's `crds/` handling ignores sync-waves →
  **split crds into their own argocd application**, applied first.
- rke2 clusters need `additionalLoggingSources.rke2.enabled: true` +
  `systemdLogPath: /var/log/journal` (or `/run/log/journal`) for node/journald.

---

## the situation-specific conclusion

because the two releases were installed **by hand via the rancher ui**, the task
is a **migration/adoption**, not a fresh install. argocd adopts existing resources
**in place** (adds tracking annotations, no pod recreation) **only if** the
declared chart + version + values **exactly match** the ui install — otherwise the
first sync is a destructive upgrade.

recommended target = 3 argocd apps, sync-wave ordered:

| app | wave | notes |
|-----|------|-------|
| `rancher-logging-crd` | -2 | `ServerSideApply=true`, `prune: false` |
| `rancher-logging` | -1 | `skipCrds: true`, values pasted verbatim from `helm get values -a` |
| `rancher-logging-config` | 0 | git-managed clusterflow/clusteroutput |

release names MUST equal the existing helm releases for clean adoption. after
migration, stop managing the app in the rancher ui (single owner per release).

---

## the load-bearing gotchas

1. **versions must match the ui install** (`helm get metadata`) and crd==operator.
2. **values must match** (`helm get values -a`, paste verbatim) or pods churn.
3. **`ServerSideApply=true`** — rancher-logging crds exceed the client-side
   `last-applied-configuration` annotation size limit → permanent `OutOfSync`.
4. **`prune: false` on crd app** — a stray sync must never delete crds.
5. **diff before sync** — adoption safe only if diff is metadata/annotation-only,
   not deployment/daemonset/statefulset replacement.
6. **single owner** — argocd vs rancher-fleet fight if both manage the release.

---

## blocker / open

could not read live cluster state. active `KUBECONFIG` pointed at a **gke
cluster** requiring `gcloud auth login` (gke-gcloud-auth-plugin failed) — the
wrong cluster; the one with the logging releases wasn't identified. still need
from the user: which kubeconfig/cluster has `cattle-logging-system`, so we can run
`helm get metadata` / `helm get values -a` and fill the app manifests for a clean
(metadata-only) diff.

---

## deliverables written (all in .tmp/rancher-logging/)

- `install-rancher-logging.md` — fresh-install / hybrid doc (rancher app installs
  operator, argocd manages flow/output) + pure-argocd 3-app alternative.
- `migrate-rancher-logging-to-argocd.md` — **the relevant one**: adopt the two
  ui-installed releases into argocd without downtime (capture → 3 apps → diff →
  sync → retire ui ownership).

no repo files changed; docs only, all under `.tmp/` per convention.

---

## sources

- rancher logging integration — https://ranchermanager.docs.rancher.com/integrations-in-rancher/logging
- rancher-logging chart options — https://ranchermanager.docs.rancher.com/integrations-in-rancher/logging/logging-helm-chart-options
- logging architecture — https://ranchermanager.docs.rancher.com/integrations-in-rancher/logging/logging-architecture
- rancher/charts (charts.rancher.io) — https://github.com/rancher/charts
- argocd onboard existing helm release — https://www.aviator.co/blog/how-to-onboard-an-existing-helm-application-in-argocd/
- argocd helm / releaseName — https://argo-cd.readthedocs.io/en/stable/user-guide/helm/
- argocd sync options (ServerSideApply) — https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
- argocd crd + sync-wave ordering — https://github.com/argoproj/argo-cd/issues/21079
