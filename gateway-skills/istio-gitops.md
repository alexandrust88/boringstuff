# istio gitops skill - istio 1.28 via argocd

deploy and operate istio service mesh via argocd using app-of-apps pattern with sync waves.

source: `./istio_work_poc/`

---

## when to use

- deploying istio 1.28+ via argocd/gitops
- migrating from iop-based (IstioOperator) to helm-based istio install
- private registry migration (air-gapped or enterprise)
- configuring istio security context for restricted psa
- production ha istiod deployments

---

## architecture: app-of-apps with sync waves

istio requires strict deployment ordering - CRDs first, then control plane, then gateways.

```text
sync-wave 0: istio-base
  chart: istio/base
  scope: cluster (CRDs, ClusterRoles)
  namespace: istio-system
  purpose: installs Gateway, VirtualService, DestinationRule, PeerAuthentication, etc. CRDs

sync-wave 1: istiod
  chart: istio/istiod
  scope: namespaced
  namespace: istio-system
  purpose: control plane (pilot) - config distribution to envoy sidecars
  depends on: base (CRDs must exist)

sync-wave 2: istio-ingressgateway
  chart: istio/gateway
  scope: namespaced
  namespace: istio-ingress
  purpose: ingress gateway (envoy proxy fleet)
  depends on: istiod
```

**critical**: if you don't use sync waves, istiod will fail with "no matches for kind" errors because CRDs aren't installed yet.

---

## argocd project definition

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: istio
  namespace: argocd
spec:
  description: istio service mesh
  sourceRepos:
    - https://git.example.com/your-org/istio-gitops.git
    - https://istio-release.storage.googleapis.com/charts
  destinations:
    - namespace: istio-system
      server: https://kubernetes.default.svc
    - namespace: istio-ingress
      server: https://kubernetes.default.svc
    - namespace: argocd
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: "apiextensions.k8s.io"
      kind: CustomResourceDefinition
    - group: "admissionregistration.k8s.io"
      kind: MutatingWebhookConfiguration
    - group: "admissionregistration.k8s.io"
      kind: ValidatingWebhookConfiguration
    - group: "rbac.authorization.k8s.io"
      kind: ClusterRole
    - group: "rbac.authorization.k8s.io"
      kind: ClusterRoleBinding
    - group: ""
      kind: Namespace
  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"
    # istio CRDs still need explicit listing to be allowed in destination namespaces
    - group: "networking.istio.io"
      kind: "*"
    - group: "security.istio.io"
      kind: "*"
    - group: "telemetry.istio.io"
      kind: "*"
    - group: "extensions.istio.io"
      kind: "*"
    - group: "gateway.networking.k8s.io"
      kind: "*"
```

---

## application manifests

**warning**: `targetRevision: main` allows silent drift whenever the git branch advances. for production, pin to a commit SHA (e.g. `targetRevision: a1b2c3d`) or a signed tag (e.g. `targetRevision: v1.28.0-gitops.3`) and bump deliberately via PR.

### root app-of-apps

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istio-root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: istio
  source:
    repoURL: https://git.example.com/your-org/istio-gitops.git
    targetRevision: main
    path: argocd/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### istio-base (sync-wave 0)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istio-base
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
  labels:
    app.kubernetes.io/part-of: istio
    app.kubernetes.io/component: base
    app.kubernetes.io/version: "1.28.0"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: istio
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-system
  sources:
    # IMPORTANT: git repo with ref MUST come first for $values to work
    - repoURL: https://git.example.com/your-org/istio-gitops.git
      targetRevision: main
      ref: values
    - repoURL: https://istio-release.storage.googleapis.com/charts
      chart: base
      targetRevision: "1.28.0"
      helm:
        valueFiles:
          - $values/helm-values/base-values.yaml
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

### istiod (sync-wave 1)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istiod
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: istio
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-system
  sources:
    - repoURL: https://git.example.com/your-org/istio-gitops.git
      targetRevision: main
      ref: values
    - repoURL: https://istio-release.storage.googleapis.com/charts
      chart: istiod
      targetRevision: "1.28.0"
      helm:
        valueFiles:
          - $values/helm-values/istiod-values.yaml
  # CRITICAL: ignore caBundle which istio auto-populates
  ignoreDifferences:
    - group: admissionregistration.k8s.io
      kind: MutatingWebhookConfiguration
      jqPathExpressions:
        - .webhooks[].clientConfig.caBundle
    - group: admissionregistration.k8s.io
      kind: ValidatingWebhookConfiguration
      jqPathExpressions:
        - .webhooks[].clientConfig.caBundle
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
    syncOptions:
      - CreateNamespace=true
      - RespectIgnoreDifferences=true
```

**gotcha**: without `ignoreDifferences` on webhook caBundle, argocd will constantly show OutOfSync because istio injects the cert dynamically.

### istio-ingressgateway (sync-wave 2)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: istio-ingressgateway
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: istio
  destination:
    server: https://kubernetes.default.svc
    namespace: istio-ingress
  sources:
    - repoURL: https://git.example.com/your-org/istio-gitops.git
      targetRevision: main
      ref: values
    - repoURL: https://istio-release.storage.googleapis.com/charts
      chart: gateway
      targetRevision: "1.28.0"
      helm:
        valueFiles:
          - $values/helm-values/gateway-values.yaml
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## namespace psa labels

relying on argocd `CreateNamespace=true` creates namespaces without pod security admission (PSA) labels. istio 1.28+ uses revision-based sidecar injection; the ingress namespace must have an injection label or the gateway pod will run without a sidecar. manage namespaces explicitly instead.

```yaml
# base/namespace.yaml - synced by istio-base or a dedicated namespaces app (sync-wave -1)
---
apiVersion: v1
kind: Namespace
metadata:
  name: istio-system
  labels:
    # control plane only - no workloads/sidecars here.
    # with istio CNI plugin installed, `baseline` is sufficient.
    # without CNI, istiod's init container needs NET_ADMIN/NET_RAW -> `privileged`.
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: Namespace
metadata:
  name: istio-ingress
  labels:
    # gateway pods need a sidecar. use revision-based injection (istio 1.28+):
    istio.io/rev: default
    # legacy equivalent (non-revisioned): istio-injection: enabled
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

**psa + istio CNI rules of thumb**:
- `restricted` works everywhere **only with istio CNI plugin** (no init container with caps).
- `baseline` is the safe middle ground: permits `NET_ADMIN`/`NET_RAW` in init containers when CNI is not installed.
- `privileged` is only needed if you run legacy iptables-based init on nodes that enforce PSA at `privileged`.

remove the `- CreateNamespace=true` sync option on each istio Application once namespaces are managed here, so PSA labels aren't silently bypassed.

---

## helm values: istiod hardened

```yaml
pilot:
  replicaCount: 1              # poc: 1, prod: 2-3
  autoscaleEnabled: true
  autoscaleMin: 1
  autoscaleMax: 5
  resources:
    requests: { cpu: 500m, memory: 2048Mi }
    limits:   { cpu: 1000m, memory: 4096Mi }
  enableProtocolSniffingForOutbound: true
  enableProtocolSniffingForInbound: true
  traceSampling: 1.0           # poc: 1.0, prod: 0.01

  # istiod pod security
  securityContext:
    runAsUser: 1337            # standard istio user
    runAsGroup: 1337
    runAsNonRoot: true
    fsGroup: 1337
  containerSecurityContext:
    runAsUser: 1337
    runAsGroup: 1337
    runAsNonRoot: true
    capabilities:
      drop: [ALL]
    # istiod writes to /tmp at runtime; true breaks it unless you add emptyDir
    # volumes for /tmp and /var/run/secrets/tokens. leave false.
    readOnlyRootFilesystem: false
    allowPrivilegeEscalation: false
    seccompProfile:
      type: RuntimeDefault

global:
  configValidation: true
  proxy:
    logLevel: warning
    enableCoreDump: false      # disable in prod
    clusterDomain: cluster.local
    resources:
      requests: { cpu: 100m, memory: 128Mi }
      limits:   { cpu: 2000m, memory: 1024Mi }
    # sidecar security
    runAsUser: 1337
    runAsGroup: 1337
    runAsNonRoot: true
    # privileged: false is only fully safe WITH the istio CNI plugin (see
    # "common customizations > istio CNI plugin" below). without CNI the init
    # container still needs NET_ADMIN/NET_RAW caps, so PSA `restricted` will reject it.
    privileged: false
    capabilities:
      drop: [ALL]
      add: [NET_BIND_SERVICE]  # for ports < 1024

meshConfig:
  accessLogFile: /dev/stdout
  enableAutoMtls: true         # preferred in 1.28+
  defaultConfig:
    tracing:
      sampling: 1.0
    holdApplicationUntilProxyStarts: true
    proxyMetadata:
      ISTIO_META_DNS_CAPTURE: "true"
      ISTIO_META_DNS_AUTO_ALLOCATE: "true"
  outboundTrafficPolicy:
    # SECURITY: ALLOW_ANY is easier for POC but permits unrestricted egress -
    # any compromised pod can exfiltrate to arbitrary external hosts. in production
    # prefer REGISTRY_ONLY and declare explicit ServiceEntry for every allowed
    # external dependency (apis, registries, vault, etc.).
    mode: ALLOW_ANY            # REGISTRY_ONLY = stricter, only mesh services
  localityLbSetting:
    enabled: true
```

## helm values: gateway hardened

```yaml
name: istio-ingressgateway
replicaCount: 1
autoscaling:
  enabled: true
  minReplicas: 1
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80

service:
  type: LoadBalancer
  ports:
    - { name: status-port, port: 15021, protocol: TCP, targetPort: 15021 }
    - { name: http2, port: 80, protocol: TCP, targetPort: 80 }
    - { name: https, port: 443, protocol: TCP, targetPort: 443 }
  annotations: {}
    # azure: service.beta.kubernetes.io/azure-load-balancer-internal: "false"
    # aws:   service.beta.kubernetes.io/aws-load-balancer-type: nlb
    # gcp:   cloud.google.com/load-balancer-type: External

resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { cpu: 2000m, memory: 1024Mi }

securityContext:
  runAsUser: 1337
  runAsGroup: 1337
  runAsNonRoot: true
  fsGroup: 1337

containerSecurityContext:
  runAsUser: 1337
  runAsGroup: 1337
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
    add: [NET_BIND_SERVICE]    # for binding to 80/443
  seccompProfile:
    type: RuntimeDefault

podDisruptionBudget:
  minAvailable: 1

serviceAccount:
  create: true
  annotations: {}
    # aws irsa:   eks.amazonaws.com/role-arn: arn:aws:iam::xxx:role/istio-gateway
    # gcp wi:     iam.gke.io/gcp-service-account: istio-gw@proj.iam.gserviceaccount.com
```

---

## phase 2: private registry migration

### step 1: mirror container images

**warning**: plain `docker pull` + `docker push` copies only the host's architecture (typically amd64). istio publishes multi-arch manifests (amd64 + arm64). copying a single arch breaks arm64 nodes. use `skopeo copy --multi-arch all` or `docker buildx imagetools create` instead.

```bash
#!/bin/bash
ISTIO_VERSION="1.28.0"
SOURCE_REGISTRY="docker.io/istio"
TARGET_REGISTRY="your-registry.example.com/istio"

IMAGES=(
  "pilot"        # istiod
  "proxyv2"      # sidecar + gateway
  # optional:
  # "ztunnel"        # ambient mode
  # "install-cni"    # CNI plugin
)

# preferred: skopeo preserves the multi-arch manifest list
for img in "${IMAGES[@]}"; do
  skopeo copy --multi-arch all \
    docker://${SOURCE_REGISTRY}/${img}:${ISTIO_VERSION} \
    docker://${TARGET_REGISTRY}/${img}:${ISTIO_VERSION}
done

# alternative: docker buildx imagetools (retags the existing manifest list)
# for img in "${IMAGES[@]}"; do
#   docker buildx imagetools create \
#     --tag ${TARGET_REGISTRY}/${img}:${ISTIO_VERSION} \
#     ${SOURCE_REGISTRY}/${img}:${ISTIO_VERSION}
# done
```

### step 2: mirror helm charts (oci)

```bash
# pull from upstream
helm pull istio/base --version 1.28.0
helm pull istio/istiod --version 1.28.0
helm pull istio/gateway --version 1.28.0

# push to oci registry
helm push base-1.28.0.tgz oci://your-registry.example.com/helm-charts
helm push istiod-1.28.0.tgz oci://your-registry.example.com/helm-charts
helm push gateway-1.28.0.tgz oci://your-registry.example.com/helm-charts
```

### step 3: update helm values

```yaml
# uncomment in base-values.yaml, istiod-values.yaml, gateway-values.yaml:
global:
  hub: your-registry.example.com/istio
  tag: "1.28.0"
  imagePullSecrets:
    - name: your-registry-secret
```

### step 4: argocd repo credentials

```yaml
# private helm/oci registry
apiVersion: v1
kind: Secret
metadata:
  name: helm-registry-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  url: https://your-registry.example.com/helm-charts
  username: <username>
  password: <password>
  enableOCI: "true"
```

---

## troubleshooting

### crds not installing

symptom: istiod fails with "no matches for kind VirtualService"

```bash
# verify base sync-wave completes first
argocd app sync istio-base
argocd app wait istio-base --health

# then sync istiod
argocd app sync istiod
```

### gateway pending (no external ip)

```bash
kubectl describe svc istio-ingressgateway -n istio-ingress

# check events for loadbalancer provisioning errors
# for bare metal: change service.type to NodePort
```

### webhook cabundle drift

if you see OutOfSync on MutatingWebhookConfiguration/ValidatingWebhookConfiguration caBundle:
- add `ignoreDifferences` with `jqPathExpressions` for `.webhooks[].clientConfig.caBundle`
- add `RespectIgnoreDifferences=true` to syncOptions

### sync failures

```bash
argocd app get <app-name> --show-operation
kubectl describe application <app-name> -n argocd
kubectl logs -n argocd deploy/argocd-application-controller --tail=100 | grep istio
```

### mtls not working

```bash
# check peerauthentication
kubectl get peerauthentication -A

# check if mtls is enabled in mesh config
kubectl get configmap istio -n istio-system -o yaml | grep enableAutoMtls

# check tls settings on destination rule
kubectl get destinationrule -A -o yaml | grep -A 5 tls:
```

---

## common customizations

### strict mtls mesh-wide

**WARNING**: applying `PeerAuthentication` with `mode: STRICT` at cluster scope without a rolling migration will break every pod that doesn't yet have a sidecar (ingress-nginx, prometheus scrapes, kube-system, cronjobs, legacy workloads). recommended rollout:

- step 1: enable `enableAutoMtls: true` in meshConfig (already in istiod-values above).
- step 2: deploy `PeerAuthentication` with `mode: PERMISSIVE` **namespace-by-namespace** so both plaintext and mtls are accepted while workloads get sidecars.
- step 3: verify coverage with `istioctl x authz check <pod>.<ns>` and the `istio_requests_total{security_policy="mutual_tls"}` metric (expect near-100% per workload).
- step 4: promote to `mode: STRICT` per namespace, then finally mesh-wide once every workload is verified.

never jump straight to cluster-wide `STRICT`.

```yaml
# in istiod-values.yaml meshConfig:
meshConfig:
  enableAutoMtls: true

---
# step 2/4 example - note: v1 is preferred from istio 1.22+; v1beta1 still works.
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: PERMISSIVE   # flip to STRICT only after step 3 verification
```

### ha istiod (production)

```yaml
pilot:
  replicaCount: 3       # initial replicas; HPA will adjust
  autoscaleMin: 3
  autoscaleMax: 10
```

**gotcha**: once the HPA kicks in it owns `.spec.replicas` on the Deployment. argocd will then fight the HPA (constant OutOfSync / selfHeal churn). fix by telling argocd to ignore that field:

```yaml
# in the istiod Application spec (next to ignoreDifferences for caBundle):
ignoreDifferences:
  - group: apps
    kind: Deployment
    name: istiod
    namespace: istio-system
    jsonPointers:
      - /spec/replicas
```

remember to also add `- RespectIgnoreDifferences=true` to `syncOptions`.

### istio CNI plugin (required for restricted psa / `privileged: false`)

by default istio injects an init container (`istio-init`) with `NET_ADMIN` + `NET_RAW` capabilities into every sidecar-enabled pod to program iptables redirects. this is incompatible with the `restricted` PSA profile and is why `privileged: false` alone isn't enough - the init container still needs caps.

installing the istio CNI plugin moves that iptables setup into a privileged daemonset on the node, so application pods (and gateway pods) need **no caps and no init container**, which lets them run under PSA `restricted` with `privileged: false`.

```yaml
# base-values.yaml - enable the CNI plugin as an additional chart/app
# (commented out in the source poc, enable before promoting to restricted PSA):
# istio_cni:
#   enabled: true

# deploy the chart as another argocd Application (sync-wave 0 alongside base):
# - repoURL: https://istio-release.storage.googleapis.com/charts
#   chart: cni
#   targetRevision: "1.28.0"
```

without CNI:
- sidecar/gateway init container requires `capabilities: { add: [NET_ADMIN, NET_RAW] }`
- namespace PSA must be `baseline` (not `restricted`)
- `global.proxy.privileged` can still be `false` but the init container makes the pod effectively non-restricted

with CNI:
- no init container needed; `global.proxy.privileged: false` is genuinely sufficient
- namespaces can enforce `restricted`
- CNI daemonset itself runs privileged on nodes (acceptable trade-off: one privileged component vs. every pod)

docs: <https://istio.io/latest/docs/setup/additional-setup/cni/>

### canary upgrades

```yaml
revision: "canary"  # set on istiod-values.yaml

# deploy new istiod alongside existing
# label namespaces with istio.io/rev=canary for gradual rollout
```

---

## validation commands

```bash
# check CRDs installed
kubectl get crd | grep istio

# check istiod
kubectl get pods -n istio-system
kubectl logs -n istio-system -l app=istiod --tail=50

# check gateway
kubectl get pods -n istio-ingress
kubectl get svc istio-ingressgateway -n istio-ingress

# check proxy config from istiod
kubectl exec -n istio-system deploy/istiod -- curl -s localhost:15014/debug/syncz

# check proxy readiness
istioctl proxy-status

# inspect envoy config on a specific sidecar (subcommands cover each xds resource)
istioctl proxy-config cluster   <pod>.<namespace>
istioctl proxy-config listeners <pod>.<namespace>
istioctl proxy-config routes    <pod>.<namespace>
istioctl proxy-config endpoints <pod>.<namespace>
# narrow noisy output, e.g. only endpoints for a service:
istioctl proxy-config endpoints <pod>.<namespace> --cluster "outbound|80||myservice.myns.svc.cluster.local"

# analyze for issues
istioctl analyze -A
```
