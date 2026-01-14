# Phase 2: Migration to Private Registry

This guide covers migrating Envoy Gateway Helm charts and container images to your private registry.

## Overview

After POC validation, you'll want to:
1. Mirror Envoy Gateway container images to your private registry
2. Mirror Envoy Gateway Helm charts to your private OCI registry
3. Update ArgoCD Applications to use private sources

## Step 1: Mirror Container Images

### Images to Mirror (Envoy Gateway v1.3.0)

```bash
# Envoy Gateway controller
docker.io/envoyproxy/gateway:v1.3.0

# Envoy Proxy (data plane)
docker.io/envoyproxy/envoy:distroless-v1.32.0

# Rate Limit (if using rate limiting)
docker.io/envoyproxy/ratelimit:latest
```

### Mirror Script Example

```bash
#!/bin/bash
EG_VERSION="v1.3.0"
ENVOY_VERSION="distroless-v1.32.0"
SOURCE_REGISTRY="docker.io/envoyproxy"
TARGET_REGISTRY="your-registry.example.com/envoyproxy"

IMAGES=(
  "gateway:${EG_VERSION}"
  "envoy:${ENVOY_VERSION}"
  "ratelimit:latest"
)

for img in "${IMAGES[@]}"; do
  docker pull ${SOURCE_REGISTRY}/${img}
  docker tag ${SOURCE_REGISTRY}/${img} ${TARGET_REGISTRY}/${img}
  docker push ${TARGET_REGISTRY}/${img}
done
```

## Step 2: Mirror Helm Charts

### Pull and Push to OCI Registry

```bash
# Login to source registry (if needed)
helm registry login docker.io

# Pull chart
helm pull oci://docker.io/envoyproxy/gateway-helm --version v1.3.0

# Push to your OCI registry
helm push gateway-helm-v1.3.0.tgz oci://your-registry.example.com/helm-charts
```

## Step 3: Update ArgoCD Applications

See `envoy-gateway-app-private.yaml` for the updated Application manifest.

### Key Changes

1. Update `repoURL` to point to your private OCI registry
2. Override image repositories in Helm values:
   - `deployment.envoyGateway.image.repository`
   - `config.envoyGateway.provider.kubernetes.envoyDeployment.container.image`
3. Add `imagePullSecrets` configuration

## Step 4: Configure ArgoCD Credentials

### For Private OCI Registry

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
  url: your-registry.example.com
  username: <username>
  password: <password>
  enableOCI: "true"
```

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
  url: https://github.com/YOUR_ORG/envoy-gateway-gitops.git
  username: git
  password: <github-token>
```

## Step 5: Create Image Pull Secret

```bash
kubectl create secret docker-registry registry-credentials \
  --docker-server=your-registry.example.com \
  --docker-username=<username> \
  --docker-password=<password> \
  -n envoy-gateway-system
```

## Validation Checklist

- [ ] Container images mirrored and accessible
- [ ] Helm chart mirrored and accessible
- [ ] ArgoCD can authenticate to private registries
- [ ] Application manifest updated with private URLs
- [ ] ImagePullSecret created in envoy-gateway-system namespace
- [ ] Test deployment in staging environment
- [ ] Verify Envoy proxy pods use private image
