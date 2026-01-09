# ArgoCD Migration Examples

This document provides concrete examples for migrating ArgoCD from Kubernetes Ingress to Envoy Gateway HTTPRoute.

## Table of Contents

1. [Basic Ingress to HTTPRoute Conversion](#basic-ingress-to-httproute-conversion)
2. [TLS Configuration Comparison](#tls-configuration-comparison)
3. [Path-Based Routing Examples](#path-based-routing-examples)
4. [Host-Based Routing Examples](#host-based-routing-examples)
5. [gRPC Configuration Examples](#grpc-configuration-examples)
6. [Complete Production Examples](#complete-production-examples)

---

## Basic Ingress to HTTPRoute Conversion

### Example 1: Simple ArgoCD Ingress (nginx)

**Original Ingress (nginx-ingress):**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  tls:
    - hosts:
        - argocd.example.com
      secretName: argocd-tls
  rules:
    - host: argocd.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
```

**Equivalent HTTPRoute:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-server
    app.kubernetes.io/part-of: argocd
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
      sectionName: https  # Reference specific listener
  hostnames:
    - "argocd.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80  # Use HTTP port - TLS terminates at Gateway
```

### Example 2: Simple ArgoCD Ingress (Traefik)

**Original Ingress (Traefik):**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    kubernetes.io/ingress.class: traefik
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  tls:
    - hosts:
        - argocd.example.com
      secretName: argocd-tls
  rules:
    - host: argocd.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
```

**Equivalent HTTPRoute:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "argocd.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
```

---

## TLS Configuration Comparison

### Ingress TLS (Per-Ingress)

With Ingress, TLS is configured per-resource:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
spec:
  tls:
    - hosts:
        - argocd.example.com
      secretName: argocd-tls  # Secret in same namespace
  rules:
    - host: argocd.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
```

### Gateway TLS (Centralized)

With Gateway API, TLS is configured at the Gateway level:

**Step 1: Gateway with TLS Listener**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: envoy-gateway-system
spec:
  gatewayClassName: envoy-gateway
  listeners:
    # HTTP listener (optional - for redirect)
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All

    # HTTPS listener with TLS termination
    - name: https
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - name: wildcard-tls
            kind: Secret
      allowedRoutes:
        namespaces:
          from: All

    # Alternative: Per-hostname TLS
    - name: https-argocd
      port: 443
      protocol: HTTPS
      hostname: "argocd.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - name: argocd-tls
            kind: Secret
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              kubernetes.io/metadata.name: argocd
```

**Step 2: HTTPRoute (No TLS Config Needed)**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
      sectionName: https-argocd  # Reference specific listener
  hostnames:
    - "argocd.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
```

### TLS with Cert-Manager

**Ingress with Cert-Manager:**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - hosts:
        - argocd.example.com
      secretName: argocd-tls
  rules:
    - host: argocd.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
```

**Gateway with Cert-Manager:**
```yaml
# Certificate resource
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-tls
  namespace: envoy-gateway-system  # Must be in Gateway namespace
spec:
  secretName: argocd-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - argocd.example.com
---
# Gateway references the certificate
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: envoy-gateway-system
spec:
  gatewayClassName: envoy-gateway
  listeners:
    - name: https-argocd
      port: 443
      protocol: HTTPS
      hostname: "argocd.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - name: argocd-tls
```

---

## Path-Based Routing Examples

### Example 1: ArgoCD with Separate Paths

**Ingress with Path-Based Routing:**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-paths
  namespace: argocd
spec:
  tls:
    - hosts:
        - argocd.example.com
      secretName: argocd-tls
  rules:
    - host: argocd.example.com
      http:
        paths:
          # API endpoints
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
          # Static assets
          - path: /assets
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
          # Webhook endpoints
          - path: /api/webhook
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
          # Default - UI
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
```

**HTTPRoute with Path-Based Routing:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-paths
  namespace: argocd
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "argocd.example.com"
  rules:
    # API endpoints - most specific first
    - matches:
        - path:
            type: PathPrefix
            value: /api/webhook
      backendRefs:
        - name: argocd-server
          port: 80

    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: argocd-server
          port: 80

    # Static assets
    - matches:
        - path:
            type: PathPrefix
            value: /assets
      backendRefs:
        - name: argocd-server
          port: 80

    # Default - UI (catch-all)
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
```

### Example 2: Path Matching Types

**HTTPRoute with Different Path Types:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-path-types
  namespace: argocd
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "argocd.example.com"
  rules:
    # Exact match - only /healthz exactly
    - matches:
        - path:
            type: Exact
            value: /healthz
      backendRefs:
        - name: argocd-server
          port: 80

    # Prefix match - /api and all subpaths
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: argocd-server
          port: 80

    # RegularExpression match (if supported)
    - matches:
        - path:
            type: RegularExpression
            value: "/applications/[a-z0-9-]+/resource-tree"
      backendRefs:
        - name: argocd-server
          port: 80
```

---

## Host-Based Routing Examples

### Example 1: Multi-Host ArgoCD Setup

**Ingress with Multiple Hosts:**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-multi-host
  namespace: argocd
spec:
  tls:
    - hosts:
        - argocd.example.com
        - argocd.internal.example.com
      secretName: argocd-tls
  rules:
    # Public hostname
    - host: argocd.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
    # Internal hostname
    - host: argocd.internal.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 443
```

**HTTPRoute with Multiple Hosts:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-multi-host
  namespace: argocd
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "argocd.example.com"
    - "argocd.internal.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
```

### Example 2: Environment-Specific Routing

**Separate HTTPRoutes per Environment:**
```yaml
# Production ArgoCD
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-prod
  namespace: argocd
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "argocd.prod.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
---
# Staging ArgoCD
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-staging
  namespace: argocd-staging
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "argocd.staging.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
```

### Example 3: Wildcard Host Matching

**HTTPRoute with Wildcard:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-wildcard
  namespace: argocd
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "*.argocd.example.com"  # Matches any subdomain
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
```

---

## gRPC Configuration Examples

ArgoCD uses gRPC for CLI communication. Here are different approaches:

### Option 1: gRPC-Web via HTTPRoute (Recommended)

ArgoCD supports gRPC-Web, which works over standard HTTP/2:

**HTTPRoute for gRPC-Web:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "argocd.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
```

**CLI Usage:**
```bash
# Use --grpc-web flag
argocd login argocd.example.com --grpc-web
```

### Option 2: Dedicated GRPCRoute

For native gRPC (without grpc-web):

**GRPCRoute:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: argocd-grpc
  namespace: argocd
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
      sectionName: grpc  # Reference gRPC listener
  hostnames:
    - "argocd-grpc.example.com"
  rules:
    - backendRefs:
        - name: argocd-server
          port: 443  # gRPC port
```

**Gateway with gRPC Listener:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: envoy-gateway-system
spec:
  gatewayClassName: envoy-gateway
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - name: argocd-tls
      allowedRoutes:
        namespaces:
          from: All

    - name: grpc
      port: 8443
      protocol: HTTPS  # gRPC over TLS
      tls:
        mode: Terminate
        certificateRefs:
          - name: argocd-tls
      allowedRoutes:
        kinds:
          - kind: GRPCRoute
        namespaces:
          from: All
```

### Option 3: Same Port for HTTP and gRPC

Using HTTP/2 for both:

**Combined HTTPRoute:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-combined
  namespace: argocd
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "argocd.example.com"
  rules:
    # gRPC requests (content-type: application/grpc)
    - matches:
        - headers:
            - name: content-type
              value: application/grpc
      backendRefs:
        - name: argocd-server
          port: 443

    # Regular HTTP requests
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
```

---

## Complete Production Examples

### Example 1: Full ArgoCD Migration Setup

**Gateway Configuration:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: envoy-gateway-system
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
spec:
  gatewayClassName: envoy-gateway
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All

    - name: https
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - name: wildcard-tls
      allowedRoutes:
        namespaces:
          from: All
```

**HTTP to HTTPS Redirect:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-https-redirect
  namespace: argocd
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
      sectionName: http
  hostnames:
    - "argocd.example.com"
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

**Main ArgoCD HTTPRoute:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-server
    app.kubernetes.io/part-of: argocd
    app.kubernetes.io/component: server
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
      sectionName: https
  hostnames:
    - "argocd.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
      timeouts:
        request: 300s  # 5 minute timeout for long operations
```

### Example 2: ArgoCD with Health Checks and Timeouts

**HTTPRoute with Filters:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "argocd.example.com"
  rules:
    # Health check endpoint - no auth required
    - matches:
        - path:
            type: Exact
            value: /healthz
      backendRefs:
        - name: argocd-server
          port: 80

    # API with custom headers
    - matches:
        - path:
            type: PathPrefix
            value: /api
      filters:
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            add:
              - name: X-Content-Type-Options
                value: nosniff
              - name: X-Frame-Options
                value: DENY
      backendRefs:
        - name: argocd-server
          port: 80

    # Default route
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
```

**Backend Health Check Policy (Envoy Gateway Extension):**
```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: argocd-health-check
  namespace: argocd
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: argocd-server
  healthCheck:
    active:
      type: HTTP
      http:
        path: /healthz
        expectedStatuses:
          - start: 200
            end: 299
      interval: 10s
      timeout: 5s
      unhealthyThreshold: 3
      healthyThreshold: 2
```

### Example 3: Multi-Cluster ArgoCD Configuration

**Helm Values for Different Environments:**
```yaml
# values-production.yaml
argocd:
  httproute:
    enabled: true
    hostname: "argocd.prod.example.com"
    gateway:
      name: main-gateway
      namespace: envoy-gateway-system
    tls:
      enabled: true
      secretName: argocd-prod-tls
    grpc:
      enabled: true
      mode: grpc-web
    timeouts:
      request: 300s
```

```yaml
# values-staging.yaml
argocd:
  httproute:
    enabled: true
    hostname: "argocd.staging.example.com"
    gateway:
      name: main-gateway
      namespace: envoy-gateway-system
    tls:
      enabled: true
      secretName: argocd-staging-tls
    grpc:
      enabled: true
      mode: grpc-web
    timeouts:
      request: 60s
```

---

## Migration Checklist

Use this checklist when converting each Ingress:

- [ ] Identify current Ingress annotations and their purposes
- [ ] Map annotations to Gateway API equivalents
- [ ] Create HTTPRoute with correct hostnames
- [ ] Configure parentRefs to reference correct Gateway/listener
- [ ] Set up path matching rules
- [ ] Configure timeouts if needed
- [ ] Test with temporary hostname first
- [ ] Validate TLS termination
- [ ] Test gRPC/CLI connectivity
- [ ] Perform DNS cutover
- [ ] Monitor for errors
- [ ] Remove old Ingress after validation period

---

## Common Annotation Mappings

| Ingress Annotation | Gateway API Equivalent |
|--------------------|------------------------|
| `nginx.ingress.kubernetes.io/ssl-redirect` | HTTPRoute RequestRedirect filter |
| `nginx.ingress.kubernetes.io/proxy-body-size` | BackendTrafficPolicy |
| `nginx.ingress.kubernetes.io/proxy-read-timeout` | HTTPRoute timeouts |
| `nginx.ingress.kubernetes.io/proxy-send-timeout` | HTTPRoute timeouts |
| `nginx.ingress.kubernetes.io/backend-protocol` | BackendTLSPolicy |
| `nginx.ingress.kubernetes.io/cors-*` | HTTPRoute filters or EnvoyPatchPolicy |
| `nginx.ingress.kubernetes.io/whitelist-source-range` | SecurityPolicy |

---

## References

- [Migration Guide](./MIGRATION-ARGOCD.md)
- [Gateway API Specification](https://gateway-api.sigs.k8s.io/)
- [Envoy Gateway Documentation](https://gateway.envoyproxy.io/)
- [ArgoCD Ingress Configuration](https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/)
