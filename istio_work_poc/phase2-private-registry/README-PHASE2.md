# Phase 2: Migration to Private Registry

This guide covers migrating Istio Helm charts and container images to your private registry.

## Overview

After POC validation, you'll want to:
1. Mirror Istio container images to your private registry
2. Mirror Istio Helm charts to your private Helm repo (or OCI registry)
3. Update ArgoCD Applications to use private sources

## Step 1: Mirror Container Images

### Images to Mirror (Istio 1.28.0)

```bash
# Core images
docker.io/istio/pilot:1.28.0
docker.io/istio/proxyv2:1.28.0

# Optional (if using specific features)
docker.io/istio/ztunnel:1.28.0     # For ambient mode
docker.io/istio/install-cni:1.28.0 # For CNI plugin
```

### Mirror Script Example

```bash
#!/bin/bash
ISTIO_VERSION="1.28.0"
SOURCE_REGISTRY="docker.io/istio"
TARGET_REGISTRY="your-registry.example.com/istio"

IMAGES=(
  "pilot"
  "proxyv2"
)

for img in "${IMAGES[@]}"; do
  docker pull ${SOURCE_REGISTRY}/${img}:${ISTIO_VERSION}
  docker tag ${SOURCE_REGISTRY}/${img}:${ISTIO_VERSION} ${TARGET_REGISTRY}/${img}:${ISTIO_VERSION}
  docker push ${TARGET_REGISTRY}/${img}:${ISTIO_VERSION}
done
```

## Step 2: Mirror Helm Charts

### Option A: OCI Registry (Recommended)

ArgoCD supports OCI-based Helm charts natively.

```bash
# Pull charts from upstream
helm pull istio/base --version 1.28.0
helm pull istio/istiod --version 1.28.0
helm pull istio/gateway --version 1.28.0

# Push to OCI registry
helm push base-1.28.0.tgz oci://your-registry.example.com/helm-charts
helm push istiod-1.28.0.tgz oci://your-registry.example.com/helm-charts
helm push gateway-1.28.0.tgz oci://your-registry.example.com/helm-charts
```

### Option B: ChartMuseum / Harbor Helm Repo

```bash
# Upload to ChartMuseum
curl --data-binary "@base-1.28.0.tgz" https://chartmuseum.example.com/api/charts
curl --data-binary "@istiod-1.28.0.tgz" https://chartmuseum.example.com/api/charts
curl --data-binary "@gateway-1.28.0.tgz" https://chartmuseum.example.com/api/charts
```

## Step 3: Update ArgoCD Applications

See the template files in this directory for updated Application manifests.

### Key Changes

1. Update `repoURL` to point to your private registry
2. Update `global.hub` in Helm values
3. Add `imagePullSecrets` if required
4. Configure ArgoCD repository credentials

## Step 4: Configure ArgoCD Credentials

### For Private Git Repo

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: private-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/YOUR_ORG/istio-gitops.git
  username: git
  password: <github-token>
```

### For Private Helm/OCI Registry

```yaml
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
  enableOCI: "true"  # For OCI registries
```

## Validation Checklist

- [ ] Container images mirrored and accessible
- [ ] Helm charts mirrored and accessible
- [ ] ArgoCD can authenticate to private registries
- [ ] Application manifests updated with private URLs
- [ ] ImagePullSecrets created in target namespaces
- [ ] Test deployment in staging environment
