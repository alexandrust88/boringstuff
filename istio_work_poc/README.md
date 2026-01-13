# Istio 1.28 ArgoCD GitOps POC

This repository provides a complete App-of-Apps pattern for deploying Istio 1.28 via ArgoCD.

## Quick Start

### Prerequisites

- Kubernetes cluster (1.25+)
- ArgoCD installed in the cluster
- `kubectl` configured to access your cluster

### 1. Update Repository URLs

Before deploying, update the Git repository URL in all Application manifests:

```bash
# Replace YOUR_ORG with your GitHub org/user
find argocd/ -name "*.yaml" -exec sed -i '' 's|YOUR_ORG|your-actual-org|g' {} \;
```

Files to update:
- `argocd/apps/root-app.yaml` - root App-of-Apps
- `argocd/apps/istio-base-app.yaml`
- `argocd/apps/istiod-app.yaml`
- `argocd/apps/istio-gateway-app.yaml`
- `argocd/project/istio-project.yaml`

### 2. Push to Your Git Repository

```bash
git init
git add .
git commit -m "Initial Istio 1.28 ArgoCD setup"
git remote add origin https://github.com/YOUR_ORG/istio-gitops.git
git push -u origin main
```

### 3. Deploy via ArgoCD

**Option A: App-of-Apps (Recommended)**

Deploy the root application which will create all child applications:

```bash
# Apply the project first
kubectl apply -f argocd/project/istio-project.yaml

# Apply the root app
kubectl apply -f argocd/apps/root-app.yaml
```

**Option B: Individual Applications**

Deploy each application separately:

```bash
kubectl apply -f argocd/project/istio-project.yaml
kubectl apply -f argocd/apps/istio-base-app.yaml
# Wait for CRDs...
kubectl apply -f argocd/apps/istiod-app.yaml
# Wait for istiod...
kubectl apply -f argocd/apps/istio-gateway-app.yaml
```

### 4. Monitor Deployment

```bash
# Using ArgoCD CLI
argocd app list
argocd app get istio-base
argocd app get istiod
argocd app get istio-ingressgateway

# Using kubectl
kubectl get applications -n argocd
kubectl get pods -n istio-system
kubectl get pods -n istio-ingress
```

## Directory Structure

```
istio_work_poc/
├── argocd/
│   ├── apps/
│   │   ├── root-app.yaml           # App-of-Apps entry point
│   │   ├── istio-namespace.yaml    # Namespace definitions
│   │   ├── istio-base-app.yaml     # CRDs (sync-wave: 0)
│   │   ├── istiod-app.yaml         # Control plane (sync-wave: 1)
│   │   └── istio-gateway-app.yaml  # Ingress gateway (sync-wave: 2)
│   └── project/
│       └── istio-project.yaml      # ArgoCD Project definition
├── base/
│   ├── namespace.yaml              # Namespace manifests
│   └── kustomization.yaml
├── helm-values/
│   ├── base-values.yaml            # Istio base Helm values
│   ├── istiod-values.yaml          # Istiod Helm values
│   └── gateway-values.yaml         # Gateway Helm values
├── phase2-private-registry/        # Phase 2 migration templates
│   ├── README-PHASE2.md
│   ├── istio-base-app-private.yaml
│   ├── istiod-app-private.yaml
│   ├── gateway-app-private.yaml
│   └── registry-credentials-secret.yaml
├── scripts/
│   ├── deploy-poc.sh               # POC deployment script
│   ├── mirror-images.sh            # Image mirroring for Phase 2
│   └── mirror-charts.sh            # Chart mirroring for Phase 2
└── README.md
```

## Sync Wave Order

| Wave | Application | Description |
|------|-------------|-------------|
| 0 | istio-base | CRDs and cluster-scoped resources |
| 1 | istiod | Control plane (pilot) |
| 2 | istio-ingressgateway | Ingress gateway |

## Customization

### Helm Values

Modify the files in `helm-values/` to customize your Istio deployment:

- **base-values.yaml**: Global settings, proxy defaults
- **istiod-values.yaml**: Control plane config, mTLS, mesh settings
- **gateway-values.yaml**: Gateway service type, ports, resources

### Common Customizations

**Change Gateway Service Type (e.g., for bare metal):**

```yaml
# helm-values/gateway-values.yaml
service:
  type: NodePort  # or ClusterIP with external LB
```

**Enable mTLS Strict Mode:**

```yaml
# helm-values/istiod-values.yaml
meshConfig:
  enableAutoMtls: true
```

**Increase Replicas for HA:**

```yaml
# helm-values/istiod-values.yaml
pilot:
  replicaCount: 3
  autoscaleMin: 3
```

## Phase 2: Private Registry Migration

See [phase2-private-registry/README-PHASE2.md](phase2-private-registry/README-PHASE2.md) for instructions on:

1. Mirroring container images to private registry
2. Mirroring Helm charts to private OCI/Helm repo
3. Updating ArgoCD Applications for private sources
4. Configuring registry credentials

## Troubleshooting

### CRDs Not Installing

If istiod fails with missing CRDs, ensure istio-base sync-wave completes first:

```bash
argocd app sync istio-base
# Wait for it to be healthy
argocd app sync istiod
```

### Gateway Pending

If the gateway service stays in Pending state, check your cloud provider's load balancer:

```bash
kubectl describe svc -n istio-ingress
```

For bare metal, change service type to `NodePort`.

### Sync Failures

Check ArgoCD application status:

```bash
argocd app get <app-name> --show-operation
kubectl describe application <app-name> -n argocd
```

## References

- [Istio Helm Installation](https://istio.io/latest/docs/setup/install/helm/)
- [ArgoCD Multiple Sources](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/)
- [ArgoCD Sync Waves](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/)
