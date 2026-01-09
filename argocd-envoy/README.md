# ArgoCD Envoy Gateway Integration

Helm chart for exposing ArgoCD through Envoy Gateway with cert-manager TLS.

## Overview

This chart creates:
- **Certificate**: cert-manager Certificate for TLS
- **HTTPRoute**: Routes HTTPS traffic to ArgoCD server
- **HTTPRoute (redirect)**: Redirects HTTP to HTTPS
- **GRPCRoute**: Routes gRPC traffic for ArgoCD CLI
- **BackendTrafficPolicy**: Active health checks
- **BackendTrafficPolicy**: Rate limiting (optional)

## Prerequisites

1. Envoy Gateway installed (use `envoy-gateway-chart`)
2. Gateway resource created with HTTP (80) and HTTPS (443) listeners
3. cert-manager installed with ClusterIssuer configured
4. ArgoCD installed

## Installation

```bash
# Staging
helm upgrade --install argocd-envoy ./argocd-envoy \
  -f values.yaml \
  -f values-staging.yaml \
  -n envoy-gateway-system

# Production
helm upgrade --install argocd-envoy ./argocd-envoy \
  -f values.yaml \
  -f values-prod.yaml \
  -n envoy-gateway-system
```

## Configuration

### Required Values

```yaml
hostname: argocd.yourdomain.com

gateway:
  name: envoy-gateway
  namespace: envoy-gateway-system

tls:
  certificate:
    issuerRef:
      name: letsencrypt-prod
      kind: ClusterIssuer
```

### TLS with cert-manager

The chart creates a cert-manager Certificate that:
- Uses ECDSA P-256 for optimal performance
- Auto-renews 15 days before expiry
- Supports additional DNS names

```yaml
tls:
  enabled: true
  secretName: argocd-tls
  certificate:
    enabled: true
    issuerRef:
      name: letsencrypt-prod
      kind: ClusterIssuer
    dnsNames:
      - argocd-alt.yourdomain.com
    duration: 2160h   # 90 days
    renewBefore: 360h # 15 days
```

### Using Existing Certificate

If you already have a TLS secret:

```yaml
tls:
  enabled: true
  secretName: existing-tls-secret
  certificate:
    enabled: false  # Don't create Certificate
```

### gRPC for ArgoCD CLI

The chart creates a GRPCRoute for `argocd` CLI commands:

```yaml
grpc:
  enabled: true
  port: 443
```

Usage:
```bash
argocd login argocd.yourdomain.com --grpc-web
```

### Rate Limiting

Enable rate limiting for production:

```yaml
rateLimit:
  enabled: true
  requestsPerUnit: 100
  unit: minute
```

### Security Headers

Default security headers are enabled:

```yaml
securityHeaders:
  enabled: true
  headers:
    X-Frame-Options: DENY
    X-Content-Type-Options: nosniff
    X-XSS-Protection: "1; mode=block"
    Referrer-Policy: strict-origin-when-cross-origin
```

## Gateway Listener Requirements

Your Gateway must have these listeners:

```yaml
listeners:
  - name: http
    protocol: HTTP
    port: 80
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
        - kind: Secret
          name: argocd-tls  # Matches tls.secretName
```

## Verification

```bash
# Check Certificate
kubectl get certificate -n envoy-gateway-system

# Check HTTPRoute
kubectl get httproute -n envoy-gateway-system

# Check GRPCRoute
kubectl get grpcroute -n envoy-gateway-system

# Test HTTPS
curl -I https://argocd.yourdomain.com

# Test ArgoCD CLI
argocd login argocd.yourdomain.com --grpc-web
```

## Troubleshooting

### Certificate not ready

```bash
kubectl describe certificate argocd-envoy -n envoy-gateway-system
kubectl get challenges -A
```

### HTTPRoute not working

```bash
kubectl get httproute -n envoy-gateway-system -o yaml
kubectl get gateway -n envoy-gateway-system -o yaml
```

### gRPC not connecting

Ensure ArgoCD server has gRPC enabled:
```yaml
# ArgoCD ConfigMap
server.insecure: "true"  # TLS is handled by Envoy
```
