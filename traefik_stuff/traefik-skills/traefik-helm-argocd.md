# traefik - helm & argocd gitops

deploying traefik v3.7.x (chart `40.x`) via helm and managing it with argocd app-of-apps + sync waves.

chart repo: `https://traefik.github.io/charts` · chart `40.1.0+` → appVersion `v3.7.1`.

> reminder: the chart is the `40.x` series. there is **no** chart `0.40.0`. for v3.7.1 use chart `40.1.0` or `40.2.0`.

---

## chart anatomy (the values that matter)

```yaml
# --- providers: which config sources traefik watches ---
providers:
  kubernetesCRD:
    enabled: true
    allowCrossNamespace: false        # set true to ref Middleware across namespaces
    allowExternalNameServices: false
    allowEmptyServices: true
  kubernetesIngress:
    enabled: true                     # vanilla Ingress (non-nginx-annotated)
    allowExternalNameServices: false
    allowEmptyServices: true
  kubernetesIngressNGINX:
    enabled: false                    # the nginx-compat provider (turn ON to replace nginx)
    controllerClass: "k8s.io/ingress-nginx"
    publishService: { enabled: true } # set false during nginx coexistence
  kubernetesGateway:
    enabled: false                    # gateway api v1.5
    experimentalChannel: false

# --- deployment ---
deployment:
  enabled: true
  kind: Deployment                    # or DaemonSet for host-network edge
  replicas: 2
  terminationGracePeriodSeconds: 60
  minReadySeconds: 0

# --- listeners ---
ports:
  web:
    port: 8000
    exposedPort: 80
    expose: { default: true }
    # redirectTo: { port: websecure }   # global http->https
  websecure:
    port: 8443
    exposedPort: 443
    expose: { default: true }
    http:
      tls: { enabled: true }
  traefik:
    port: 8080                        # internal api/dashboard/ping/metrics — DO NOT expose
    expose: { default: false }

# --- external exposure ---
service:
  enabled: true
  spec: { type: LoadBalancer }        # one external IP for the whole controller

# --- ingressClass ownership ---
ingressClass:
  enabled: true
  isDefaultClass: true                # false while migrating off nginx
  name: ""                            # "" = chart default name

# --- dashboard (behind auth only) ---
ingressRoute:
  dashboard:
    enabled: false
    matchRule: PathPrefix(`/dashboard`) || PathPrefix(`/api`)
    entryPoints: ["traefik"]

# --- observability ---
metrics:
  prometheus:
    service: { enabled: true }
    serviceMonitor: { enabled: true }
logs:
  general: { level: INFO }
  access: { enabled: true, format: json }

# --- resources / scheduling ---
resources:
  requests: { cpu: 200m, memory: 256Mi }
  limits:   { cpu: 1000m, memory: 1Gi }

# --- escape hatch: raw static-config flags ---
additionalArguments: []
```

---

## three install profiles

### profile 1 — nginx replacement (compat, coexisting with nginx)

```yaml
# values-compat.yaml
deployment: { replicas: 2 }
providers:
  kubernetesIngressNGINX:
    enabled: true
    controllerClass: "k8s.io/ingress-nginx"
    publishService: { enabled: false }   # don't fight nginx over Ingress .status
  kubernetesCRD:     { enabled: true }   # allow adding native Middleware later
  kubernetesIngress: { enabled: false }  # nginx provider already owns nginx-class ingresses
ingressClass:
  enabled: true
  isDefaultClass: false                  # don't steal default while nginx lives
service: { spec: { type: LoadBalancer } }
```

```bash
helm upgrade --install traefik traefik/traefik \
  -n traefik --create-namespace --version 40.1.0 -f values-compat.yaml
```

### profile 2 — native / greenfield

```yaml
# values-native.yaml
deployment: { replicas: 3 }
providers:
  kubernetesCRD:     { enabled: true, allowCrossNamespace: true }
  kubernetesIngress: { enabled: true }
ingressClass: { enabled: true, isDefaultClass: true }
service: { spec: { type: LoadBalancer } }
ports:
  web: { redirectTo: { port: websecure } }
```

### profile 3 — gateway api (v1.5)

```yaml
# values-gateway.yaml
providers:
  kubernetesGateway: { enabled: true }
  kubernetesCRD:     { enabled: true }
# gateway api CRDs must be installed in the cluster (chart can install standard channel)
```

---

## argocd app-of-apps

### structure

```
traefik-app-of-apps/
├── traefik.yaml            # wave 0: helm release (controller + CRDs + ingressClass)
├── traefik-tls.yaml        # wave 1: TLSOption + cluster-wide Middleware
└── traefik-routes.yaml     # wave 2: IngressRoute (or leave existing nginx Ingress in place)
```

### wave 0 — controller

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: platform
  source:
    repoURL: https://traefik.github.io/charts
    chart: traefik
    targetRevision: 40.1.0
    helm:
      valueFiles: []
      values: |
        deployment: { replicas: 2 }
        providers:
          kubernetesIngressNGINX: { enabled: true, publishService: { enabled: false } }
          kubernetesCRD: { enabled: true }
        ingressClass: { enabled: true, isDefaultClass: false }
        service: { spec: { type: LoadBalancer } }
        metrics: { prometheus: { serviceMonitor: { enabled: true } } }
  destination:
    server: https://kubernetes.default.svc
    namespace: traefik
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true       # important for traefik CRDs (large schemas)
```

### wave 1 — cluster-wide policy

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik-tls
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: platform
  source:
    repoURL: https://gitlab.example.com/platform/traefik-config.git
    targetRevision: main
    path: tls
  destination: { server: https://kubernetes.default.svc, namespace: traefik }
  syncPolicy: { automated: { prune: true, selfHeal: true } }
```

### wave 2 — routes (only if going native; nginx Ingress objects need no app)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik-routes
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  source:
    path: routes                    # IngressRoute/Middleware manifests
  # ...
```

### dependency ordering (why the waves)

```
wave 0: CRDs + IngressClass + controller   (must exist first)
   |  CRDs before any IngressRoute/Middleware can be applied
   |  IngressClass before Ingress objects resolve to traefik
   v
wave 1: TLSOption + shared Middleware       (referenced by routes)
   v
wave 2: IngressRoute (references wave-1 middlewares + cert secrets)
```

---

## CRD ownership gotcha (argocd + helm)

the traefik chart installs CRDs. two failure modes:

1. **prune deletes CRDs.** if argocd prunes the traefik Application, it can delete the CRDs and orphan every IngressRoute cluster-wide. mitigate:
   - put CRDs in a separate Application with `prune: false`, **or**
   - annotate CRDs `argocd.argoproj.io/sync-options: Prune=false` and `helm.sh/resource-policy: keep`.

2. **CRD schema too large for client-side apply.** traefik CRDs exceed the annotation size limit for `kubectl apply` client-side. use `ServerSideApply=true` in `syncOptions` (shown above). without it you get `metadata.annotations: Too long`.

```yaml
# CRDs as their own non-pruned app
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: traefik-crds
  annotations: { argocd.argoproj.io/sync-wave: "-1" }
spec:
  source:
    repoURL: https://traefik.github.io/charts
    chart: traefik-crds            # chart provides a CRDs-only subchart/option
    targetRevision: <crd-chart-version>
  syncPolicy:
    syncOptions: [ ServerSideApply=true ]
    automated: { prune: false }    # never prune CRDs
```

---

## multi-cluster pattern

use an `ApplicationSet` to fan the same traefik release across clusters, overriding per-cluster values (LB annotations, default-class timing, replicas):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: { name: traefik, namespace: argocd }
spec:
  generators:
    - clusters: { selector: { matchLabels: { traefik: "enabled" } } }
  template:
    metadata: { name: 'traefik-{{name}}' }
    spec:
      project: platform
      source:
        repoURL: https://traefik.github.io/charts
        chart: traefik
        targetRevision: 40.1.0
        helm:
          valueFiles:
            - '$values/clusters/{{name}}/traefik-values.yaml'   # per-cluster overlay
      sources: []   # use multi-source for $values repo ref
      destination: { server: '{{server}}', namespace: traefik }
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [ CreateNamespace=true, ServerSideApply=true ]
```

per-cluster overlay carries the things that differ:

```yaml
# clusters/prod-eu/traefik-values.yaml
deployment: { replicas: 4 }
service:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
ingressClass: { isDefaultClass: true }     # nginx already gone here
providers:
  kubernetesIngressNGINX: { publishService: { enabled: true } }
```

---

## migration-aware rollout across many clusters

during a fleet-wide nginx→traefik migration, drive the per-cluster overlay flags through gitops in stages:

| stage | overlay flags | effect |
|-------|---------------|--------|
| land | `kubernetesIngressNGINX.enabled: true`, `publishService.enabled: false`, `isDefaultClass: false` | traefik serves alongside nginx, owns nothing |
| validate | (no change) | `--resolve` tests, metrics compare |
| cutover | dns/external-LB shift (outside gitops) | traffic moves to traefik |
| own | `publishService.enabled: true`, `isDefaultClass: true` | traefik becomes the controller |
| cleanup | remove nginx Application; ensure standalone IngressClass kept | nginx gone, class preserved |

each stage is a small PR to the cluster overlay — auditable, reversible, no big-bang.

---

## references

- helm chart: https://github.com/traefik/traefik-helm-chart
- chart values: https://github.com/traefik/traefik-helm-chart/blob/master/traefik/values.yaml
- argocd app-of-apps: https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/
- argocd serverside apply: https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/#server-side-apply
