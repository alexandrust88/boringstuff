# Envoy Gateway Architecture

This document provides a deep dive into the Envoy Gateway architecture, component interactions, and traffic flow patterns used across our 60+ cluster deployment.

---

## Table of Contents

1. [Component Overview](#component-overview)
2. [Control Plane Architecture](#control-plane-architecture)
3. [Data Plane Architecture](#data-plane-architecture)
4. [Gateway API Resource Model](#gateway-api-resource-model)
5. [Policy Attachment Model](#policy-attachment-model)
6. [Traffic Flow](#traffic-flow)
7. [High Availability Design](#high-availability-design)
8. [Azure Integration Points](#azure-integration-points)
9. [Multi-Tenancy Model](#multi-tenancy-model)

---

## Component Overview

Envoy Gateway follows a control plane / data plane separation pattern:

```
+-----------------------------------------------------------------------------------+
|                              Control Plane                                        |
|  +-----------------------------------------------------------------------------+  |
|  |                    envoy-gateway-system namespace                           |  |
|  |                                                                             |  |
|  |  +-------------------+         +-------------------+                        |  |
|  |  | envoy-gateway     |         | envoy-gateway     |                        |  |
|  |  | controller        |         | controller        |                        |  |
|  |  | (leader)          |         | (standby)         |                        |  |
|  |  +--------+----------+         +-------------------+                        |  |
|  |           |                                                                 |  |
|  |           | Watches: GatewayClass, Gateway, HTTPRoute,                      |  |
|  |           |          GRPCRoute, *Policy, Service, Secret                    |  |
|  |           v                                                                 |  |
|  |  +-------------------+                                                      |  |
|  |  | Kubernetes API    |                                                      |  |
|  |  | Server            |                                                      |  |
|  |  +-------------------+                                                      |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
                                        |
                                        | Generates xDS configuration
                                        | Creates/manages Envoy Deployments
                                        v
+-----------------------------------------------------------------------------------+
|                               Data Plane                                          |
|  +-----------------------------------------------------------------------------+  |
|  |                Per-Gateway Envoy Proxy Fleet                                |  |
|  |                                                                             |  |
|  |  Gateway: argocd-gateway (namespace: argocd)                                |  |
|  |  +------------------+  +------------------+  +------------------+           |  |
|  |  | envoy-argocd-    |  | envoy-argocd-    |  | envoy-argocd-    |          |  |
|  |  | gateway-xxx      |  | gateway-yyy      |  | gateway-zzz      |          |  |
|  |  | (Envoy Proxy)    |  | (Envoy Proxy)    |  | (Envoy Proxy)    |          |  |
|  |  +------------------+  +------------------+  +------------------+           |  |
|  |                                                                             |  |
|  |  Gateway: platform-gateway (namespace: envoy-gateway-system)                |  |
|  |  +------------------+  +------------------+                                 |  |
|  |  | envoy-platform-  |  | envoy-platform-  |                                 |  |
|  |  | gateway-aaa      |  | gateway-bbb      |                                 |  |
|  |  +------------------+  +------------------+                                 |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

---

## Control Plane Architecture

### Envoy Gateway Controller

The `envoy-gateway` controller is the brain of the system. It runs as a Kubernetes Deployment with the following responsibilities:

| Responsibility | Description |
|----------------|-------------|
| **Resource Watching** | Monitors Gateway API resources (Gateway, HTTPRoute, etc.) and Envoy-specific policies |
| **xDS Server** | Runs an xDS server (gRPC-based) to push configuration to Envoy proxies |
| **Infrastructure Management** | Creates and manages Envoy Deployment, Service, and ConfigMaps |
| **Status Updates** | Updates status fields on Gateway API resources |

#### Controller Internals

```
+------------------------------------------------------------------+
|                     envoy-gateway Controller                      |
|                                                                  |
|  +------------------+    +------------------+    +--------------+ |
|  | Kubernetes       |    | IR (Intermediate |    | xDS          | |
|  | Watcher          |--->| Representation)  |--->| Translator   | |
|  | (Informers)      |    | Generator        |    |              | |
|  +------------------+    +------------------+    +------+-------+ |
|                                                         |         |
|  +------------------+    +------------------+           |         |
|  | Infrastructure   |    | xDS Server       |<----------+         |
|  | Manager          |    | (gRPC)           |                     |
|  | (Deployment/Svc) |    |                  |                     |
|  +------------------+    +--------+---------+                     |
+------------------------------------------------------------------+
                                    |
                                    | xDS Streams (ADS)
                                    v
                           +------------------+
                           | Envoy Proxies    |
                           +------------------+
```

#### Key Configuration Options

```yaml
# EnvoyGateway configuration (envoy-gateway-config ConfigMap)
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyGateway
metadata:
  name: envoy-gateway
  namespace: envoy-gateway-system
gateway:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
provider:
  type: Kubernetes
  kubernetes:
    envoyDeployment:
      replicas: 2
      pod:
        annotations:
          prometheus.io/scrape: "true"
          prometheus.io/port: "19001"
        securityContext:
          runAsNonRoot: true
      container:
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
    envoyService:
      type: LoadBalancer
      annotations:
        service.beta.kubernetes.io/azure-load-balancer-resource-group: "rg-networking"
```

---

## Data Plane Architecture

### Envoy Proxy Fleet

For each Gateway resource, Envoy Gateway creates:

1. **Deployment**: Runs Envoy Proxy pods
2. **Service**: Exposes the Gateway (LoadBalancer for external, ClusterIP for internal)
3. **ConfigMap**: Bootstrap configuration for Envoy

```
Gateway: argocd-gateway
         |
         +---> Deployment: envoy-argocd-gateway-<hash>
         |         |
         |         +---> Pod: envoy-argocd-gateway-<hash>-xxx
         |         +---> Pod: envoy-argocd-gateway-<hash>-yyy
         |
         +---> Service: envoy-argocd-gateway-<hash>
         |         Type: LoadBalancer
         |         Ports: 80, 443
         |
         +---> ConfigMap: envoy-argocd-gateway-<hash>
                   Contains: bootstrap.yaml
```

### Envoy Proxy Pod Anatomy

```
+------------------------------------------------------------------+
|                        Envoy Proxy Pod                           |
|                                                                  |
|  +------------------------------------------------------------+  |
|  |                     envoy container                        |  |
|  |                                                            |  |
|  |  Ports:                                                    |  |
|  |    - 8080: HTTP listener                                   |  |
|  |    - 8443: HTTPS listener                                  |  |
|  |    - 19001: Admin interface (metrics, config dump)         |  |
|  |                                                            |  |
|  |  Volumes:                                                  |  |
|  |    - /etc/envoy: Bootstrap config                          |  |
|  |    - /certs: TLS certificates (from Secrets)               |  |
|  |                                                            |  |
|  |  xDS Connection:                                           |  |
|  |    -> envoy-gateway.envoy-gateway-system:18000             |  |
|  +------------------------------------------------------------+  |
|                                                                  |
|  +------------------------------------------------------------+  |
|  |                 shutdown-manager container                 |  |
|  |  (handles graceful shutdown during rolling updates)        |  |
|  +------------------------------------------------------------+  |
+------------------------------------------------------------------+
```

---

## Gateway API Resource Model

### Resource Hierarchy

```
                    +-------------------+
                    |   GatewayClass    |  Cluster-scoped
                    |   (name: eg)      |  Defines controller + config
                    +---------+---------+
                              |
                              | references
                              v
                    +-------------------+
                    |     Gateway       |  Namespace-scoped
                    | argocd-gateway    |  Defines listeners (ports/TLS)
                    +---------+---------+
                              |
            +-----------------+------------------+
            |                 |                  |
            v                 v                  v
    +---------------+  +---------------+  +----------------+
    |   HTTPRoute   |  |   GRPCRoute   |  |   TCPRoute     |
    | argocd-server |  | argocd-grpc   |  | (if needed)    |
    +---------------+  +---------------+  +----------------+
            |
            v
    +---------------+
    | BackendRef    |  Points to Service
    | (Service)     |
    +---------------+
```

### GatewayClass

Cluster-wide definition that maps to an Envoy Gateway controller.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:                          # Optional: custom config
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: custom-proxy-config
    namespace: envoy-gateway-system
```

**Key Points:**
- Only one GatewayClass per Envoy Gateway installation (typically `eg`)
- Cluster-scoped (no namespace)
- Can reference EnvoyProxy resource for custom proxy configuration

### Gateway

Defines the actual ingress point with listeners.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: argocd-gateway
  namespace: argocd
spec:
  gatewayClassName: eg
  listeners:
    # HTTP listener (for redirects)
    - name: http
      protocol: HTTP
      port: 80
      hostname: "argocd.platform.example.com"
      allowedRoutes:
        namespaces:
          from: Same                       # Only routes from same namespace

    # HTTPS listener (main traffic)
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "argocd.platform.example.com"
      tls:
        mode: Terminate                    # TLS termination at gateway
        certificateRefs:
          - kind: Secret
            name: argocd-server-tls
      allowedRoutes:
        namespaces:
          from: Same

    # HTTPS listener with wildcard (multi-tenant)
    - name: https-wildcard
      protocol: HTTPS
      port: 443
      hostname: "*.apps.platform.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: wildcard-apps-tls
      allowedRoutes:
        namespaces:
          from: All                        # Routes from any namespace
        kinds:
          - kind: HTTPRoute
```

**Listener Protocols:**

| Protocol | Description | Port | Use Case |
|----------|-------------|------|----------|
| HTTP | Plain HTTP | 80 | Redirects, health checks |
| HTTPS | TLS-terminated HTTPS | 443 | Web traffic |
| TLS | TLS passthrough | 443 | Backend handles TLS |
| TCP | Raw TCP | any | Non-HTTP protocols |
| UDP | Raw UDP | any | DNS, gaming |

### HTTPRoute

Defines routing rules for HTTP/HTTPS traffic.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  parentRefs:
    - name: argocd-gateway
      sectionName: https                   # Attach to specific listener

  hostnames:
    - "argocd.platform.example.com"

  rules:
    # Rule 1: API routes
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: argocd-server
          port: 8080

    # Rule 2: Static assets with different backend
    - matches:
        - path:
            type: PathPrefix
            value: /static
      backendRefs:
        - name: argocd-static
          port: 80

    # Rule 3: Default route
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 8080
```

**Match Types:**

| Type | Example | Description |
|------|---------|-------------|
| PathPrefix | `/api` | Matches `/api`, `/api/v1`, `/api/foo/bar` |
| Exact | `/api/v1/health` | Matches only exact path |
| RegularExpression | `/api/v[0-9]+/.*` | Regex pattern (use sparingly) |
| Header | `x-version: v2` | Match by request header |
| QueryParam | `?version=2` | Match by query parameter |
| Method | `POST` | Match by HTTP method |

### GRPCRoute

Dedicated routing for gRPC traffic (critical for ArgoCD CLI).

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: argocd-grpc
  namespace: argocd
spec:
  parentRefs:
    - name: argocd-gateway
      sectionName: https

  hostnames:
    - "argocd.platform.example.com"

  rules:
    - matches:
        - method:
            service: "*"                   # All gRPC services
            method: "*"                    # All methods
      backendRefs:
        - name: argocd-server
          port: 8080
```

---

## Policy Attachment Model

Envoy Gateway extends Gateway API with custom policies using the Policy Attachment pattern.

```
                   +------------------+
                   |     Gateway      |
                   +--------+---------+
                            |
          +-----------------+------------------+
          |                                    |
          v                                    v
+-------------------+                +-------------------+
| ClientTrafficPolicy |              | SecurityPolicy    |
| (client-facing)   |                | (auth, rate limit)|
+-------------------+                +-------------------+
          |
          v
+-------------------+
|    HTTPRoute      |
+---------+---------+
          |
          v
+-------------------+
| BackendTrafficPolicy |
| (backend-facing)  |
+-------------------+
          |
          v
+-------------------+
|   BackendTLSPolicy |
| (mTLS to backend) |
+-------------------+
```

### ClientTrafficPolicy

Configures client-side connection behavior.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: argocd-client
  namespace: argocd
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: argocd-gateway

  # HTTP/2 settings (required for gRPC)
  http2:
    initialStreamWindowSize: 65536         # 64KB
    initialConnectionWindowSize: 1048576   # 1MB
    maxConcurrentStreams: 100

  # TCP keepalive
  tcpKeepalive:
    idleTime: 60s
    interval: 30s
    probes: 3

  # Client timeouts
  timeout:
    http:
      requestReceivedTimeout: 300s         # Max time to receive request

  # Connection limits
  connection:
    connectionLimit:
      value: 10000

  # TLS settings
  tls:
    minVersion: TLSv1_2
    ciphers:
      - ECDHE-ECDSA-AES128-GCM-SHA256
      - ECDHE-RSA-AES128-GCM-SHA256
```

### BackendTrafficPolicy

Configures backend connection behavior, retries, and health checks.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: argocd-backend
  namespace: argocd
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: argocd-server

  # Retry configuration
  retry:
    numRetries: 3
    perRetry:
      backOff:
        baseInterval: 100ms
        maxInterval: 1s
      timeout: 10s
    retryOn:
      triggers:
        - "5xx"
        - "gateway-error"
        - "reset"
        - "connect-failure"
      httpStatusCodes:
        - 503
        - 504

  # Timeout configuration
  timeout:
    http:
      requestTimeout: 300s                 # ArgoCD sync can be slow
      connectionIdleTimeout: 60s
    tcp:
      connectTimeout: 10s

  # Circuit breaker
  circuitBreaker:
    maxConnections: 1024
    maxPendingRequests: 1024
    maxRequests: 1024
    maxRetries: 3

  # Load balancing
  loadBalancer:
    type: LeastRequest                     # Options: RoundRobin, Random, LeastRequest
    slowStart:
      window: 30s

  # Active health checks
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

### SecurityPolicy

Configures authentication, authorization, and security controls.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: argocd-security
  namespace: argocd
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: argocd-server

  # CORS configuration
  cors:
    allowOrigins:
      - "https://argocd.platform.example.com"
    allowMethods:
      - GET
      - POST
      - PUT
      - DELETE
      - OPTIONS
    allowHeaders:
      - Authorization
      - Content-Type
      - X-Requested-With
    allowCredentials: true
    maxAge: 86400s

  # Rate limiting (local per-pod)
  rateLimit:
    type: Local
    local:
      rules:
        - limit:
            requests: 100
            unit: Minute
        # Stricter limit for login endpoint
        - clientSelectors:
            - headers:
                - name: ":path"
                  type: Exact
                  value: "/api/v1/session"
          limit:
            requests: 10
            unit: Minute

  # JWT authentication (example)
  # jwt:
  #   providers:
  #     - name: keycloak
  #       issuer: https://keycloak.example.com/realms/platform
  #       remoteJWKS:
  #         uri: https://keycloak.example.com/realms/platform/protocol/openid-connect/certs
  #       claimToHeaders:
  #         - claim: sub
  #           header: x-user-id
```

---

## Traffic Flow

### Detailed Request Path

```
Client Request (argocd.platform.example.com:443)
       |
       v
[1] Azure Load Balancer (Public IP: 20.x.x.x)
       |
       | Health probes to Envoy pods (:8443/healthz)
       |
       v
[2] Kubernetes Service (envoy-argocd-gateway-xxx)
       |
       | NodePort/ClusterIP depending on config
       |
       v
[3] Envoy Proxy Pod (Listener: 0.0.0.0:8443)
       |
       +---> [3a] TLS Termination (using argocd-server-tls secret)
       |
       +---> [3b] HTTP/2 Decoding (if HTTP/2 or gRPC)
       |
       +---> [3c] Route Matching (HTTPRoute/GRPCRoute rules)
       |           - Check hostname match
       |           - Check path/header/method match
       |           - Select backend from backendRefs
       |
       +---> [3d] Filter Chain Execution
       |           - Rate limiting check
       |           - CORS handling
       |           - Header manipulation
       |           - Authentication (if configured)
       |
       +---> [3e] Load Balancing (select backend pod)
       |
       +---> [3f] Circuit Breaker Check
       |
       +---> [3g] Retry Logic (if enabled)
       |
       v
[4] Backend Service (argocd-server:8080)
       |
       v
[5] Application Pod (argocd-server-xxx)
       |
       v
Response flows back through same path (reverse)
```

### gRPC-Specific Flow (ArgoCD CLI)

```
argocd CLI (gRPC over HTTP/2)
       |
       | grpc.argocd.platform.example.com:443
       |
       v
Envoy Proxy
       |
       +---> ClientTrafficPolicy: HTTP/2 enabled
       |     - maxConcurrentStreams: 100
       |     - initialStreamWindowSize: 65536
       |
       +---> GRPCRoute matching
       |     - service: "*"
       |     - method: "*"
       |
       +---> BackendTrafficPolicy
       |     - timeout: 300s (long sync operations)
       |     - retry on unavailable
       |
       v
ArgoCD Server (gRPC listener on :8080)
```

---

## High Availability Design

### Control Plane HA

```yaml
# values.yaml for envoy-gateway helm chart
deployment:
  envoyGateway:
    replicas: 2                            # At least 2 for HA
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi

  # Pod anti-affinity for zone distribution
  pod:
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                control-plane: envoy-gateway
            topologyKey: topology.kubernetes.io/zone

    # Spread across nodes
    topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            control-plane: envoy-gateway
```

### Data Plane HA

```yaml
# EnvoyProxy configuration for data plane HA
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: production-proxy
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        replicas: 3                        # Minimum 3 for production
        strategy:
          type: RollingUpdate
          rollingUpdate:
            maxSurge: 1
            maxUnavailable: 0              # Zero-downtime updates

        pod:
          affinity:
            podAntiAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                - labelSelector:
                    matchLabels:
                      gateway.envoyproxy.io/owning-gateway-name: argocd-gateway
                  topologyKey: topology.kubernetes.io/zone

          topologySpreadConstraints:
            - maxSkew: 1
              topologyKey: kubernetes.io/hostname
              whenUnsatisfiable: ScheduleAnyway
              labelSelector:
                matchLabels:
                  gateway.envoyproxy.io/owning-gateway-name: argocd-gateway

      envoyService:
        type: LoadBalancer
```

### Failure Scenarios

| Scenario | Impact | Mitigation |
|----------|--------|------------|
| Single Envoy pod fails | Minimal (LB routes to healthy pods) | Multiple replicas, PDB |
| All Envoy pods in one zone fail | Reduced capacity | Multi-zone spread, PDB |
| Controller pod fails | No config updates (data plane continues) | HA controller deployment |
| All controller pods fail | No config updates (data plane continues) | Quick recovery, monitoring |
| AKS node failure | Reduced capacity | Node pools, autoscaler |

---

## Azure Integration Points

### Architecture with Azure Components

```
                    +------------------------+
                    |     Azure DNS Zone     |
                    | *.platform.example.com |
                    +----------+-------------+
                               |
                               | A Record -> LB Public IP
                               v
+------------------------------------------------------------------+
|                    Azure Load Balancer                           |
|                    (Standard SKU)                                |
|                                                                  |
|  Frontend IP: 20.x.x.x (Static)                                  |
|  Backend Pool: AKS node pool                                     |
|                                                                  |
|  Health Probes:                                                  |
|    - TCP/8443 every 5s                                           |
|    - Or HTTP/8443/healthz                                        |
|                                                                  |
|  Load Balancing Rules:                                           |
|    - 80 -> NodePort 3xxxx                                        |
|    - 443 -> NodePort 3yyyy                                       |
+------------------------------------------------------------------+
                               |
                               v
+------------------------------------------------------------------+
|                         AKS Cluster                              |
|                                                                  |
|  +------------------------------------------------------------+  |
|  |              Node Pool (3+ nodes across AZs)               |  |
|  |                                                            |  |
|  |  +---------------+  +---------------+  +---------------+   |  |
|  |  | Node (AZ 1)   |  | Node (AZ 2)   |  | Node (AZ 3)   |  |  |
|  |  | - Envoy pod   |  | - Envoy pod   |  | - Envoy pod   |  |  |
|  |  +---------------+  +---------------+  +---------------+   |  |
|  +------------------------------------------------------------+  |
+------------------------------------------------------------------+
```

See [AZURE-INTEGRATION.md](./AZURE-INTEGRATION.md) for detailed Azure configuration.

---

## Multi-Tenancy Model

### Namespace Isolation

```
Cluster
├── envoy-gateway-system (Platform Team)
│   ├── GatewayClass: eg
│   ├── Gateway: shared-gateway (optional)
│   └── EnvoyProxy: production-config
│
├── argocd (Platform Team)
│   ├── Gateway: argocd-gateway
│   ├── HTTPRoute: argocd-server
│   ├── GRPCRoute: argocd-grpc
│   └── *Policy resources
│
├── team-a-prod (App Team A)
│   ├── HTTPRoute: app-a (parentRef -> shared-gateway)
│   └── BackendTrafficPolicy: app-a-policy
│
└── team-b-prod (App Team B)
    ├── HTTPRoute: app-b (parentRef -> shared-gateway)
    └── BackendTrafficPolicy: app-b-policy
```

### RBAC Model

```yaml
# Platform Team: Full control
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gateway-admin
rules:
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["gatewayclasses", "gateways"]
    verbs: ["*"]
  - apiGroups: ["gateway.envoyproxy.io"]
    resources: ["*"]
    verbs: ["*"]

---
# App Teams: Route management only
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: route-admin
  namespace: team-a-prod
rules:
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["httproutes", "grpcroutes"]
    verbs: ["*"]
  - apiGroups: ["gateway.envoyproxy.io"]
    resources: ["backendtrafficpolicies"]
    verbs: ["*"]
```

---

## Configuration Lifecycle

```
[1] Developer creates/updates HTTPRoute
              |
              v
[2] Envoy Gateway controller detects change
              |
              v
[3] Controller validates configuration
              |
              +---> Invalid: Update HTTPRoute status with error
              |
              v (Valid)
[4] Controller generates Intermediate Representation (IR)
              |
              v
[5] Controller translates IR to xDS configuration
              |
              v
[6] xDS server pushes config to Envoy proxies (ADS)
              |
              v
[7] Envoy proxies hot-reload configuration (no restart)
              |
              v
[8] Controller updates HTTPRoute status (Accepted: True)
              |
              v
[9] Traffic flows according to new configuration
```

**Key Point**: Configuration changes are applied without Envoy proxy restarts, enabling zero-downtime updates.

---

## Resource Dependencies

```
                    +-----------------+
                    |   GatewayClass  |
                    | (cluster-scoped)|
                    +--------+--------+
                             |
                             | must exist first
                             v
                    +-----------------+
                    |     Gateway     |
                    +--------+--------+
                             |
           +-----------------+------------------+
           |                 |                  |
           v                 v                  v
    +-------------+   +-------------+    +--------------+
    | HTTPRoute   |   | GRPCRoute   |    | TCPRoute     |
    +------+------+   +------+------+    +------+-------+
           |                 |                  |
           v                 v                  v
    +-------------+   +-------------+    +--------------+
    |   Service   |   |   Service   |    |   Service    |
    | (backend)   |   | (backend)   |    | (backend)    |
    +-------------+   +-------------+    +--------------+

Dependencies:
- GatewayClass must exist before Gateway
- Gateway must exist before Routes
- Services must exist before Routes (for status)
- Secrets must exist before Gateway (for TLS)
```

---

## Next Steps

- [AZURE-INTEGRATION.md](./AZURE-INTEGRATION.md) - Detailed Azure configuration
- [OPERATIONS.md](./OPERATIONS.md) - Day-2 operations and troubleshooting
