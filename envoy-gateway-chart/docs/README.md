# Envoy Gateway Documentation

## Overview

This documentation covers our production deployment of Envoy Gateway across 60+ AKS clusters (production and staging environments). Envoy Gateway serves as the Kubernetes-native ingress solution implementing the Gateway API specification, providing unified traffic management for all cluster ingress.

## Table of Contents

| Document | Description |
|----------|-------------|
| [README.md](./README.md) | This document - Overview and quick start |
| [ARCHITECTURE.md](./ARCHITECTURE.md) | Detailed architecture, components, and traffic flow |
| [AZURE-INTEGRATION.md](./AZURE-INTEGRATION.md) | Azure-specific configuration and best practices |
| [OPERATIONS.md](./OPERATIONS.md) | Day-2 operations, monitoring, and troubleshooting |
| [MIGRATION-ARGOCD.md](./MIGRATION-ARGOCD.md) | ArgoCD Ingress to Envoy Gateway migration guide |
| [MIGRATION-EXAMPLES.md](./MIGRATION-EXAMPLES.md) | Ingress to HTTPRoute conversion examples |

### Related Charts

| Chart                  | Description                                        |
|------------------------|----------------------------------------------------|
| `envoy-gateway-chart/` | This chart - Base Envoy Gateway installation       |
| `argocd-envoy/`        | ArgoCD HTTPRoute + GRPCRoute with cert-manager TLS |

---

## What is Envoy Gateway?

Envoy Gateway is an open-source project for managing Envoy Proxy as a standalone or Kubernetes-based API gateway. It implements the Kubernetes Gateway API specification, providing:

- **Kubernetes-native configuration** via Gateway API CRDs
- **Envoy Proxy** as the underlying data plane
- **Extended functionality** through Envoy-specific policy CRDs
- **Production-ready** deployment patterns with HA support

### Project Ownership

| Aspect | Details |
|--------|---------|
| Maintainer | Envoy Proxy community (CNCF graduated project) |
| License | Apache 2.0 |
| Repository | https://github.com/envoyproxy/gateway |
| Documentation | https://gateway.envoyproxy.io |
| Release Cadence | ~3 months (follows Envoy releases) |

---

## Architecture Overview

```
                                    +----------------------------------+
                                    |         Azure DNS Zone           |
                                    |   *.platform.example.com         |
                                    +----------------+-----------------+
                                                     |
                                                     v
+---------------------------------------------------------------------------------------------+
|                                    Azure Load Balancer                                      |
|                            (Standard SKU, Static Public IP)                                 |
|                                                                                             |
|    Annotations:                                                                             |
|    - service.beta.kubernetes.io/azure-load-balancer-resource-group: <rg-name>             |
|    - service.beta.kubernetes.io/azure-pip-name: <pip-name>                                 |
+---------------------------------------------------------------------------------------------+
                                                     |
                                                     | :80, :443
                                                     v
+---------------------------------------------------------------------------------------------+
|                                      AKS Cluster                                            |
|  +-----------------------------------------------------------------------------------------+|
|  |                              envoy-gateway-system namespace                             ||
|  |  +---------------------------+    +---------------------------+                         ||
|  |  |   envoy-gateway           |    |   envoy-gateway           |                         ||
|  |  |   (controller pod 1)      |    |   (controller pod 2)      |  <- HA Deployment       ||
|  |  +---------------------------+    +---------------------------+                         ||
|  |             |                                |                                          ||
|  |             +--------------------------------+                                          ||
|  |                            |                                                            ||
|  |                            v Watches Gateway API Resources                              ||
|  |  +-------------------------------------------------------------------------------------+||
|  |  |                         Envoy Proxy Fleet (per Gateway)                             |||
|  |  |  +------------------+  +------------------+  +------------------+                    |||
|  |  |  | envoy-<gw>-xxx   |  | envoy-<gw>-yyy   |  | envoy-<gw>-zzz   |  <- Data Plane    |||
|  |  |  | (proxy pod)      |  | (proxy pod)      |  | (proxy pod)      |                   |||
|  |  |  +------------------+  +------------------+  +------------------+                    |||
|  |  +-------------------------------------------------------------------------------------+||
|  +-----------------------------------------------------------------------------------------+|
|                                          |                                                  |
|                                          v Routes traffic to                                |
|  +-----------------------------------------------------------------------------------------+|
|  |                              Application Namespaces                                     ||
|  |  +------------------+  +------------------+  +------------------+                        ||
|  |  |   argocd         |  |   app-team-a     |  |   app-team-b     |                       ||
|  |  |   namespace      |  |   namespace      |  |   namespace      |                       ||
|  |  +------------------+  +------------------+  +------------------+                        ||
|  +-----------------------------------------------------------------------------------------+|
+---------------------------------------------------------------------------------------------+
```

---

## Why Envoy Gateway Over Alternatives

### Comparison Matrix

| Feature | Envoy Gateway | NGINX Ingress | Traefik |
|---------|---------------|---------------|---------|
| **Gateway API Support** | Native (core focus) | Partial/Experimental | Partial |
| **gRPC Support** | Native HTTP/2, gRPC-Web | Requires annotations | Supported |
| **Policy Attachment** | Native CRDs | Annotations only | Middleware CRDs |
| **Circuit Breaking** | Native (Envoy) | Limited | Supported |
| **Rate Limiting** | Local + Global (Redis) | External plugin | Middleware |
| **mTLS** | Native | ConfigMap-based | Supported |
| **Observability** | Native Prometheus/OTEL | Sidecar required | Native |
| **WebAssembly Extensions** | Supported | Not available | Plugins (Go) |
| **Active Health Checks** | Native | Not available | Supported |
| **CNCF Status** | Graduated (Envoy) | None | Incubating |

### Key Advantages for Our Use Case

1. **Gateway API Native**
   - Future-proof Kubernetes ingress standard
   - Portable configuration across providers
   - Role-based resource ownership (infra vs app teams)

2. **Envoy as Data Plane**
   - Battle-tested at massive scale (Google, Lyft, Stripe)
   - Advanced traffic management (retries, timeouts, circuit breaking)
   - Rich observability out of the box

3. **gRPC/HTTP2 First-Class Support**
   - Critical for ArgoCD CLI connectivity
   - WebSocket support for live logs
   - gRPC-Web for browser clients

4. **Azure Integration**
   - Works seamlessly with Azure Load Balancer
   - Static IP preservation for DNS stability
   - Health probe compatibility

5. **Enterprise Patterns**
   - Per-route rate limiting
   - JWT/OIDC authentication
   - External authorization integration

---

## Key Features

### Traffic Management

| Feature | Description | CRD |
|---------|-------------|-----|
| Path-based routing | Route by URL path prefix/exact match | HTTPRoute |
| Header-based routing | Route by request headers | HTTPRoute |
| Host-based routing | Route by hostname | HTTPRoute |
| Traffic splitting | Canary/Blue-Green deployments | HTTPRoute |
| URL rewriting | Modify path/host before backend | HTTPRoute |
| Request mirroring | Shadow traffic to secondary backend | HTTPRoute |

### Resiliency

| Feature | Description | CRD |
|---------|-------------|-----|
| Retries | Automatic retry on failure | BackendTrafficPolicy |
| Timeouts | Request/connection timeouts | BackendTrafficPolicy |
| Circuit breaking | Prevent cascade failures | BackendTrafficPolicy |
| Health checks | Active backend health monitoring | BackendTrafficPolicy |
| Load balancing | Round-robin, least-request, random | BackendTrafficPolicy |

### Security

| Feature | Description | CRD |
|---------|-------------|-----|
| TLS termination | HTTPS with certificate management | Gateway |
| mTLS | Mutual TLS for zero-trust | BackendTLSPolicy |
| Rate limiting | Local per-pod or global Redis-backed | BackendTrafficPolicy |
| JWT authentication | Token validation | SecurityPolicy |
| OIDC | OpenID Connect integration | SecurityPolicy |
| IP allow/deny | Source IP filtering | SecurityPolicy |
| CORS | Cross-origin resource sharing | SecurityPolicy |

### Observability

| Feature | Description |
|---------|-------------|
| Prometheus metrics | Request counts, latency histograms, error rates |
| Access logs | Structured JSON logs with request details |
| Distributed tracing | OpenTelemetry/Jaeger/Zipkin integration |
| Admin interface | Envoy admin API for debugging |

---

## Quick Start

### Prerequisites

- Kubernetes 1.27+ (AKS recommended)
- Helm 3.12+
- kubectl configured for target cluster
- Gateway API CRDs installed (v1.0+)

### Installation

```bash
# 1. Install Gateway API CRDs (if not present)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

# 2. Add Helm repository (OCI-based)
# Note: Envoy Gateway uses OCI registry

# 3. Install Envoy Gateway
helm install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version v1.2.0 \
  --namespace envoy-gateway-system \
  --create-namespace \
  --wait

# 4. Verify installation
kubectl get pods -n envoy-gateway-system
kubectl get gatewayclass
```

### Create Your First Gateway

```yaml
# gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: platform-gateway
  namespace: envoy-gateway-system
spec:
  gatewayClassName: eg
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
            name: wildcard-tls
```

```bash
kubectl apply -f gateway.yaml
kubectl get gateway platform-gateway -n envoy-gateway-system
```

### Create an HTTPRoute

```yaml
# httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-app-ns
spec:
  parentRefs:
    - name: platform-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "myapp.platform.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: my-app-service
          port: 8080
```

---

## Deployment Patterns

### Pattern 1: Shared Gateway (Recommended for Multi-Tenant)

Single Gateway in infrastructure namespace, HTTPRoutes in application namespaces.

```
envoy-gateway-system/
  - Gateway: platform-gateway
  - GatewayClass: eg

team-a-ns/
  - HTTPRoute: app-a (parentRef -> platform-gateway)

team-b-ns/
  - HTTPRoute: app-b (parentRef -> platform-gateway)
```

**Pros**: Centralized management, shared Load Balancer IP, consistent policies
**Cons**: Requires cross-namespace references, shared blast radius

### Pattern 2: Dedicated Gateway (Per Critical Application)

Separate Gateway for applications requiring isolation (e.g., ArgoCD).

```
argocd/
  - Gateway: argocd-gateway
  - HTTPRoute: argocd-server
  - GRPCRoute: argocd-grpc
  - ClientTrafficPolicy: http2-config
  - BackendTrafficPolicy: retry-timeout
```

**Pros**: Isolation, custom policies, dedicated IP
**Cons**: More Load Balancer IPs, higher cost

### Our Standard: Hybrid Approach

- **Dedicated Gateway** for: ArgoCD, Vault, monitoring stack
- **Shared Gateway** for: Application workloads per environment

---

## Repository Structure

```
envoy-gateway-chart/
├── Chart.yaml                    # Helm chart metadata with upstream dependency
├── values.yaml                   # Default configuration values
├── templates/
│   └── extras/                   # Additional resources (Gateway, Routes, Policies)
└── docs/
    ├── README.md                 # This document
    ├── ARCHITECTURE.md           # Detailed architecture
    ├── AZURE-INTEGRATION.md      # Azure-specific configuration
    └── OPERATIONS.md             # Day-2 operations guide
```

---

## Version Compatibility

| Component | Minimum Version | Recommended | Notes |
|-----------|-----------------|-------------|-------|
| Kubernetes | 1.27 | 1.29+ | Gateway API v1 requires 1.27+ |
| Gateway API CRDs | v1.0.0 | v1.2.0 | Install before Envoy Gateway |
| Envoy Gateway | v1.0.0 | v1.2.0 | Follow upstream releases |
| Helm | 3.12 | 3.14+ | OCI registry support required |
| ArgoCD | 2.8 | 2.12+ | For GitOps deployment |

---

## Support and Escalation

| Issue Type | First Response | Escalation Path |
|------------|----------------|-----------------|
| Gateway not accepting connections | Platform On-Call | #platform-alerts Slack |
| Route not working | Application team self-service | Platform Office Hours |
| Performance degradation | Application team investigation | Platform Engineering |
| Security vulnerability | Immediate patch cycle | Security Team |

---

## Related Documentation

- [Envoy Gateway Official Docs](https://gateway.envoyproxy.io)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io)
- [Envoy Proxy Documentation](https://www.envoyproxy.io/docs/envoy/latest/)
- [Azure Load Balancer](https://learn.microsoft.com/en-us/azure/load-balancer/)

---

## Document Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0.0 | 2025-01-09 | Platform Team | Initial documentation |
