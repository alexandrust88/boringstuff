# Envoy Gateway for ArgoCD

## Structure

```
envoy-gateway-argocd/
├── application.yaml       # Multi-source ArgoCD App (simple)
├── application-helm.yaml  # Helm-based ArgoCD App (templated)
├── extras/                # Raw manifests for multi-source
│   ├── kustomization.yaml
│   ├── gateway.yaml
│   ├── httproute.yaml
│   ├── grpcroute.yaml
│   └── policies.yaml
└── chart/                 # Helm chart wrapper
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
```

## Option 1: Multi-Source (Simple)

Uses ArgoCD multi-source to deploy upstream Helm chart + extras.

```bash
# Update hostname in extras/*.yaml
sed -i 's/argocd.example.com/YOUR-HOSTNAME/g' extras/*.yaml

# Deploy
kubectl apply -f application.yaml
```

## Option 2: Helm Chart (Templated)

Wraps upstream chart with templated extras.

```bash
# Update values in application-helm.yaml or chart/values.yaml
# Deploy
kubectl apply -f application-helm.yaml
```

## Prerequisites

1. ArgoCD must run with `--insecure` (TLS terminates at gateway):
   ```bash
   kubectl patch cm argocd-cmd-params-cm -n argocd \
     --type merge -p '{"data":{"server.insecure":"true"}}'
   kubectl rollout restart deployment argocd-server -n argocd
   ```

2. TLS secret must exist:
   ```bash
   kubectl get secret argocd-server-tls -n argocd
   ```

## Test

```bash
# Get gateway IP
kubectl get gateway argocd-gateway -n argocd

# Test HTTPS
curl -k https://argocd.example.com/

# Test CLI
argocd login argocd.example.com --insecure --grpc-web
```
