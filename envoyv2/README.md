# Envoy Gateway ArgoCD GitOps POC

This repository provides a complete App-of-Apps pattern for deploying Envoy Gateway via ArgoCD.

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
- `argocd/apps/root-app.yaml`
- `argocd/apps/envoy-gateway-app.yaml`
- `argocd/apps/gateway-class-app.yaml`
- `argocd/apps/gateway-app.yaml`
- `argocd/project/envoy-gateway-project.yaml`

### 2. Push to Your Git Repository

```bash
git init
git add .
git commit -m "Initial Envoy Gateway ArgoCD setup"
git remote add origin https://github.com/YOUR_ORG/envoy-gateway-gitops.git
git push -u origin main
```

### 3. Deploy via ArgoCD

**Option A: App-of-Apps (Recommended)**

```bash
# Apply the project first
kubectl apply -f argocd/project/envoy-gateway-project.yaml

# Apply the root app
kubectl apply -f argocd/apps/root-app.yaml
```

**Option B: Individual Applications**

```bash
kubectl apply -f argocd/project/envoy-gateway-project.yaml
kubectl apply -f argocd/apps/envoy-gateway-app.yaml
# Wait for controller...
kubectl apply -f argocd/apps/gateway-class-app.yaml
kubectl apply -f argocd/apps/gateway-app.yaml
```

### 4. Monitor Deployment

```bash
# Using ArgoCD CLI
argocd app list
argocd app get envoy-gateway

# Using kubectl
kubectl get applications -n argocd
kubectl get pods -n envoy-gateway-system
kubectl get gatewayclass
kubectl get gateways -A
```

## Directory Structure

```
envoyv2/
├── argocd/
│   ├── apps/
│   │   ├── root-app.yaml              # App-of-Apps entry point
│   │   ├── envoy-gateway-app.yaml     # Controller (sync-wave: 0)
│   │   ├── gateway-class-app.yaml     # GatewayClass (sync-wave: 1)
│   │   └── gateway-app.yaml           # Gateway instance (sync-wave: 2)
│   └── project/
│       └── envoy-gateway-project.yaml # ArgoCD Project
├── base/
│   └── namespace.yaml                 # Namespace with PSS labels
├── extras/
│   ├── gateway-class/
│   │   └── gatewayclass.yaml
│   └── gateway/
│       ├── gateway.yaml
│       └── envoy-proxy-config.yaml    # EnvoyProxy CRD
├── helm-values/
│   └── envoy-gateway-values.yaml      # Helm values with security context
├── phase2-private-registry/
│   ├── README-PHASE2.md
│   └── envoy-gateway-app-private.yaml
├── scripts/
│   ├── deploy-poc.sh
│   └── mirror-images.sh
└── README.md
```

## Sync Wave Order

| Wave | Application | Description |
|------|-------------|-------------|
| 0 | envoy-gateway | Controller and CRDs |
| 1 | gateway-class | GatewayClass definition |
| 2 | gateway-instance | Gateway resource |

## Security Features

All components are configured with hardened security contexts:

| Setting | Value |
|---------|-------|
| `runAsNonRoot` | `true` |
| `runAsUser` | `65532` |
| `runAsGroup` | `65532` |
| `readOnlyRootFilesystem` | `true` |
| `allowPrivilegeEscalation` | `false` |
| `capabilities.drop` | `ALL` |
| `capabilities.add` | `NET_BIND_SERVICE` (proxy only) |
| `seccompProfile.type` | `RuntimeDefault` |

The namespace is labeled with Pod Security Standards (restricted).

## Customization

### Helm Values

Modify `helm-values/envoy-gateway-values.yaml` to customize:

- Resource limits and requests
- Replica counts
- HPA settings
- Service type and annotations
- Logging levels

### Gateway Configuration

Modify `extras/gateway/gateway.yaml` to customize:

- Listeners (ports, protocols)
- TLS configuration
- Allowed routes

### EnvoyProxy Configuration

Modify `extras/gateway/envoy-proxy-config.yaml` to customize:

- Access log format
- Telemetry settings
- Proxy deployment settings

## Phase 2: Private Registry Migration

See [phase2-private-registry/README-PHASE2.md](phase2-private-registry/README-PHASE2.md) for instructions on:

1. Mirroring container images
2. Mirroring Helm charts to OCI registry
3. Updating ArgoCD Applications
4. Configuring registry credentials

## Troubleshooting

### Controller Not Starting

Check controller logs:
```bash
kubectl logs -n envoy-gateway-system -l app.kubernetes.io/name=envoy-gateway
```

### Gateway Not Ready

Check GatewayClass status:
```bash
kubectl describe gatewayclass envoy
```

Check Gateway status:
```bash
kubectl describe gateway -n envoy-gateway-system envoy-gateway
```

### Envoy Proxy Pods Not Appearing

Envoy proxy pods are created dynamically when a Gateway is created. Check:
```bash
kubectl get pods -n envoy-gateway-system
kubectl get events -n envoy-gateway-system
```

## References

- [Envoy Gateway Documentation](https://gateway.envoyproxy.io/)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)
- [ArgoCD Multi-Source Applications](https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/)
