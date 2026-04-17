# envoy gateway - resource patterns

gateway api resource templates and patterns for envoy gateway deployments.

---

## gatewayclass

cluster-scoped. defines which controller handles gateways.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  # optional: reference custom proxy config
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: custom-proxy-config
    namespace: envoy-gateway-system
```

rules:
- only one GatewayClass per envoy gateway installation
- cluster-scoped (no namespace)
- must exist before any Gateway resource
- name "eg" is conventional but configurable

---

## gateway

namespace-scoped. defines the actual ingress point with listeners.

### basic gateway (http + https)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: envoy-gateway-system
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: "*.platform.example.com"
      allowedRoutes:
        namespaces:
          from: All

    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.platform.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: wildcard-tls
      allowedRoutes:
        namespaces:
          from: All
```

### gateway with namespace restrictions

```yaml
listeners:
  - name: https
    protocol: HTTPS
    port: 443
    hostname: "argocd.platform.example.com"
    tls:
      mode: Terminate
      certificateRefs:
        - kind: Secret
          name: argocd-server-tls
    allowedRoutes:
      namespaces:
        from: Same              # only routes from same namespace
      kinds:
        - kind: HTTPRoute       # only httproutes (no grpc, tcp)
```

### gateway with cross-namespace tls secret

requires a ReferenceGrant in the secret's namespace:

```yaml
# gateway references secret in another namespace
listeners:
  - name: https
    tls:
      certificateRefs:
        - kind: Secret
          name: argocd-server-tls
          namespace: argocd       # cross-namespace

---
# referencegrant in the secret's namespace
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-tls
  namespace: argocd
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: Gateway
      namespace: envoy-gateway-system
  to:
    - group: ""
      kind: Secret
      name: argocd-server-tls
```

### listener protocols

| protocol | port | use case |
|----------|------|----------|
| HTTP | 80 | redirects, health checks, plaintext |
| HTTPS | 443 | tls-terminated web traffic |
| TLS | 443 | tls passthrough (backend handles tls) |
| TCP | any | raw tcp, non-http protocols |
| UDP | any | dns, gaming |

### allowedRoutes.namespaces.from options

| value | meaning |
|-------|---------|
| Same | only routes in same namespace as gateway |
| All | routes from any namespace |
| Selector | routes from namespaces matching label selector |

---

## httproute

### basic httproute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app-route
  namespace: app-ns
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
      sectionName: https          # attach to specific listener
  hostnames:
    - "app.platform.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: app-service
          port: 8080
```

### httproute with multiple rules

```yaml
rules:
  # api routes to api backend
  - matches:
      - path:
          type: PathPrefix
          value: /api
    backendRefs:
      - name: api-service
        port: 8080

  # static assets to cdn backend
  - matches:
      - path:
          type: PathPrefix
          value: /static
    backendRefs:
      - name: static-service
        port: 80

  # health check endpoint
  - matches:
      - path:
          type: Exact
          value: /healthz
    backendRefs:
      - name: app-service
        port: 8080

  # default catch-all
  - matches:
      - path:
          type: PathPrefix
          value: /
    backendRefs:
      - name: app-service
        port: 8080
```

### http-to-https redirect

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-redirect
  namespace: envoy-gateway-system
spec:
  parentRefs:
    - name: main-gateway
      sectionName: http           # attach to HTTP listener
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

### httproute with header-based routing

```yaml
rules:
  - matches:
      - headers:
          - name: x-version
            value: v2
        path:
          type: PathPrefix
          value: /api
    backendRefs:
      - name: api-v2
        port: 8080

  - matches:
      - path:
          type: PathPrefix
          value: /api
    backendRefs:
      - name: api-v1
        port: 8080
```

### httproute with response header manipulation

```yaml
rules:
  - matches:
      - path:
          type: PathPrefix
          value: /
    filters:
      - type: ResponseHeaderModifier
        responseHeaderModifier:
          set:
            - name: X-Frame-Options
              value: DENY
            - name: X-Content-Type-Options
              value: nosniff
            - name: Strict-Transport-Security
              value: "max-age=31536000; includeSubDomains"
    backendRefs:
      - name: app-service
        port: 8080
```

### match types reference

| type | field | example | description |
|------|-------|---------|-------------|
| PathPrefix | path.type | `/api` | matches /api, /api/v1, /api/foo |
| Exact | path.type | `/api/v1/health` | exact match only |
| RegularExpression | path.type | `/api/v[0-9]+/.*` | regex (use sparingly) |
| Header | headers | `x-version: v2` | match by request header |
| QueryParam | queryParams | `?version=2` | match by query parameter |
| Method | method | `POST` | match by http method |

---

## grpcroute

critical for services that use grpc (e.g., argocd cli).

### basic grpcroute

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
            service: "*"          # all grpc services
            method: "*"           # all methods
      backendRefs:
        - name: argocd-server
          port: 8080
```

### grpcroute with service-specific matching

```yaml
rules:
  - matches:
      - method:
          service: "argocd.ArgoCD"
          method: "Sync"
    backendRefs:
      - name: argocd-server
        port: 8080
```

prerequisites for grpc:
- ClientTrafficPolicy with http/2 enabled on the gateway
- backend must support http/2 or grpc
- tls termination at gateway (grpc requires https)

---

## envoyproxy (custom resource)

configures the envoy proxy fleet created for each gateway.

### production envoyproxy

```yaml
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
        replicas: 3
        strategy:
          type: RollingUpdate
          rollingUpdate:
            maxSurge: 1
            maxUnavailable: 0       # zero-downtime updates
        pod:
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            runAsGroup: 65532
            fsGroup: 65532
            seccompProfile:
              type: RuntimeDefault
          affinity:
            podAntiAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                - labelSelector:
                    matchLabels:
                      gateway.envoyproxy.io/owning-gateway-name: main-gateway
                  topologyKey: topology.kubernetes.io/zone
          topologySpreadConstraints:
            - maxSkew: 1
              topologyKey: kubernetes.io/hostname
              whenUnsatisfiable: ScheduleAnyway
              labelSelector:
                matchLabels:
                  gateway.envoyproxy.io/owning-gateway-name: main-gateway
        container:
          resources:
            requests: { cpu: 500m, memory: 512Mi }
            limits: { cpu: 2000m, memory: 2Gi }

      envoyService:
        type: LoadBalancer
        externalTrafficPolicy: Local

  telemetry:
    accessLog:
      settings:
        - format:
            type: JSON
            json:
              start_time: "%START_TIME%"
              method: "%REQ(:METHOD)%"
              path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
              protocol: "%PROTOCOL%"
              response_code: "%RESPONSE_CODE%"
              response_flags: "%RESPONSE_FLAGS%"
              bytes_received: "%BYTES_RECEIVED%"
              bytes_sent: "%BYTES_SENT%"
              duration: "%DURATION%"
              upstream_service_time: "%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%"
              x_forwarded_for: "%REQ(X-FORWARDED-FOR)%"
              user_agent: "%REQ(USER-AGENT)%"
              request_id: "%REQ(X-REQUEST-ID)%"
              authority: "%REQ(:AUTHORITY)%"
              upstream_host: "%UPSTREAM_HOST%"
              upstream_cluster: "%UPSTREAM_CLUSTER%"
              grpc_status: "%GRPC_STATUS%"
          sinks:
            - type: File
              file:
                path: /dev/stdout
    metrics:
      prometheus: {}
```

---

## clienttrafficpolicy

configures client-side connection behavior. attaches to gateway.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: production-client
  namespace: argocd
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: argocd-gateway

  # http/2 (required for grpc)
  http2:
    initialStreamWindowSize: 65536
    initialConnectionWindowSize: 1048576
    maxConcurrentStreams: 100

  # tcp keepalive
  tcpKeepalive:
    idleTime: 60s
    interval: 30s
    probes: 3

  # client timeouts
  timeout:
    http:
      requestReceivedTimeout: 300s

  # connection limits
  connection:
    connectionLimit:
      value: 10000

  # tls settings
  tls:
    minVersion: TLSv1_2
    ciphers:
      - ECDHE-ECDSA-AES128-GCM-SHA256
      - ECDHE-RSA-AES128-GCM-SHA256
      - ECDHE-ECDSA-AES256-GCM-SHA384
      - ECDHE-RSA-AES256-GCM-SHA384
```

---

## backendtrafficpolicy

configures backend connection behavior. attaches to httproute.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: app-backend
  namespace: app-ns
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: app-route

  # retries
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
      httpStatusCodes: [503, 504]

  # timeouts
  timeout:
    http:
      requestTimeout: 300s
      connectionIdleTimeout: 60s
    tcp:
      connectTimeout: 10s

  # circuit breaker
  circuitBreaker:
    maxConnections: 1024
    maxPendingRequests: 1024
    maxRequests: 1024
    maxRetries: 3

  # load balancing
  loadBalancer:
    type: LeastRequest         # RoundRobin, Random, LeastRequest
    slowStart:
      window: 30s

  # active health checks
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

---

## securitypolicy

configures auth, rate limiting, cors. attaches to httproute.

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: app-security
  namespace: app-ns
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: app-route

  # cors
  cors:
    allowOrigins:
      - "https://app.platform.example.com"
    allowMethods: [GET, POST, PUT, DELETE, OPTIONS]
    allowHeaders: [Authorization, Content-Type, X-Requested-With]
    allowCredentials: true
    maxAge: 86400s

  # rate limiting (local per-pod)
  rateLimit:
    type: Local
    local:
      rules:
        - limit:
            requests: 100
            unit: Minute
        # stricter limit for auth endpoints
        - clientSelectors:
            - headers:
                - name: ":path"
                  type: Exact
                  value: "/api/v1/session"
          limit:
            requests: 10
            unit: Minute

  # ip allowlisting
  authorization:
    defaultAction: Deny
    rules:
      - name: internal
        action: Allow
        principal:
          clientCIDRs: ["10.0.0.0/8", "172.16.0.0/12"]
```

---

## backendtlspolicy

for backends that require https (e.g., argocd in secure mode).

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTLSPolicy
metadata:
  name: argocd-backend-tls
  namespace: argocd
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: argocd-server
  validation:
    wellKnownCACertificates: System
    hostname: argocd-server
```

---

## common patterns

### shared gateway + per-app routes (multi-tenant)

```
envoy-gateway-system/
  Gateway: shared-gateway (wildcard *.apps.example.com)

team-a-ns/
  HTTPRoute: app-a (parentRef -> shared-gateway)
  BackendTrafficPolicy: app-a-policy

team-b-ns/
  HTTPRoute: app-b (parentRef -> shared-gateway)
  BackendTrafficPolicy: app-b-policy
```

### dedicated gateway per app (isolation)

```
argocd/
  Gateway: argocd-gateway (argocd.example.com)
  HTTPRoute: argocd-server
  GRPCRoute: argocd-grpc
  ClientTrafficPolicy: argocd-client
  BackendTrafficPolicy: argocd-backend
```

### when to use shared vs dedicated gateway

| criteria | shared | dedicated |
|----------|--------|-----------|
| isolation requirements | low | high |
| separate tls certs | no | yes |
| different lb ip | no | yes |
| independent scaling | no | yes |
| cost (lb per gateway) | lower | higher |
