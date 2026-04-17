# envoy gateway - argocd integration

patterns for configuring argocd (ui + grpc cli) behind envoy gateway.

---

## argocd requirements

argocd needs two types of connectivity:
1. **https** - web ui, api, webhooks
2. **grpc** - argocd cli (`argocd login`, `argocd app sync`)

both go through the same hostname:port (443). envoy must handle both protocols.

---

## argocd backend mode decision

### option a: insecure mode (recommended with gateway tls termination)

argocd accepts plain http. gateway handles all tls.

```bash
# enable insecure mode
kubectl patch cm argocd-cmd-params-cm -n argocd \
  --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd
```

then route to port 80:
```yaml
backendRefs:
  - name: argocd-server
    port: 80
```

pros: simpler, no backend tls complexity
cons: traffic between gateway and argocd is unencrypted (ok within cluster)

### option b: secure mode with BackendTLSPolicy

argocd stays in secure mode (https). gateway re-encrypts to backend.

```yaml
backendRefs:
  - name: argocd-server
    port: 443

---
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

pros: end-to-end encryption
cons: more complex, need to trust argocd's self-signed cert

---

## complete argocd gateway setup

### gateway

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: argocd-gateway
  namespace: argocd
spec:
  gatewayClassName: eg
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: "argocd.platform.example.com"
      allowedRoutes:
        namespaces:
          from: Same

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
          from: Same
```

### http-to-https redirect

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-http-redirect
  namespace: argocd
spec:
  parentRefs:
    - name: argocd-gateway
      sectionName: http
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

### httproute for web ui + api

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  parentRefs:
    - name: argocd-gateway
      sectionName: https
  hostnames:
    - "argocd.platform.example.com"
  rules:
    # health check
    - matches:
        - path:
            type: Exact
            value: /healthz
      backendRefs:
        - name: argocd-server
          port: 80

    # main route with security headers
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
        - name: argocd-server
          port: 80
```

### grpcroute for cli

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
            service: "*"
            method: "*"
      backendRefs:
        - name: argocd-server
          port: 80
```

### clienttrafficpolicy (http/2 for grpc)

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
  http2:
    initialStreamWindowSize: 65536
    initialConnectionWindowSize: 1048576
    maxConcurrentStreams: 100
  tcpKeepalive:
    idleTime: 60s
    interval: 30s
    probes: 3
```

### backendtrafficpolicy

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
  retry:
    numRetries: 3
    perRetry:
      backOff:
        baseInterval: 100ms
        maxInterval: 1s
      timeout: 10s
    retryOn:
      triggers: ["5xx", "gateway-error", "reset", "connect-failure"]
      httpStatusCodes: [503, 504]
  timeout:
    http:
      requestTimeout: 300s            # argocd sync can be slow
      connectionIdleTimeout: 60s
    tcp:
      connectTimeout: 10s
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

## argocd-envoy helm chart

a dedicated helm chart for argocd httproute configuration is available at:
`./argocd-envoy/`

### values structure

```yaml
# hostname for argocd
hostname: argocd.platform.example.com

# gateway reference
gateway:
  name: argocd-gateway
  namespace: argocd

# tls configuration
tls:
  enabled: true
  certificate:
    create: true
    issuerRef:
      name: letsencrypt-prod
      kind: ClusterIssuer
    algorithm: ECDSA
    size: 256
    renewBefore: 360h              # 15 days

# http redirect
httpRedirect:
  enabled: true
  statusCode: 301

# grpc support
grpc:
  enabled: true

# timeouts
timeout:
  request: 300s
  idle: 60s
  connect: 10s

# health checks
healthCheck:
  enabled: true
  path: /healthz
  interval: 10s

# rate limiting
rateLimit:
  enabled: false
  requestsPerMinute: 100
  loginRequestsPerMinute: 10

# security headers
securityHeaders:
  enabled: true
```

### deployment

```bash
# staging
helm upgrade --install argocd-envoy ./argocd-envoy \
  -f argocd-envoy/values.yaml \
  -f argocd-envoy/values-staging.yaml \
  -n argocd \
  --set hostname=argocd.staging.example.com \
  --set tls.certificate.issuerRef.name=letsencrypt-staging

# production
helm upgrade --install argocd-envoy ./argocd-envoy \
  -f argocd-envoy/values.yaml \
  -f argocd-envoy/values-prod.yaml \
  -n argocd \
  --set hostname=argocd.platform.example.com \
  --set tls.certificate.issuerRef.name=letsencrypt-prod
```

### staging vs production differences

| setting | staging | production |
|---------|---------|------------|
| tls issuer | letsencrypt-staging | letsencrypt-prod |
| timeout.request | 60s | 300s |
| rate limiting | disabled | enabled |
| csp | relaxed | strict |

---

## testing argocd with envoy gateway

### connectivity tests

```bash
# get gateway ip
GW_IP=$(kubectl get gateway argocd-gateway -n argocd -o jsonpath='{.status.addresses[0].value}')

# test https (web ui)
curl -v --resolve argocd.platform.example.com:443:$GW_IP https://argocd.platform.example.com/

# test api
curl -s --resolve argocd.platform.example.com:443:$GW_IP https://argocd.platform.example.com/api/version | jq .

# test grpc (cli)
argocd login argocd.platform.example.com --grpc-web --insecure

# test health
curl -s --resolve argocd.platform.example.com:443:$GW_IP https://argocd.platform.example.com/healthz
```

### common 500 error with argocd

the most common issue: argocd is NOT in insecure mode, so port 80 returns nothing.

diagnosis:
```bash
# check insecure mode
kubectl get cm argocd-cmd-params-cm -n argocd -o jsonpath='{.data.server\.insecure}'
# if empty or "false" -> argocd requires https on backend

# fix option a: enable insecure
kubectl patch cm argocd-cmd-params-cm -n argocd \
  --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd

# fix option b: use port 443 + backendtlspolicy
```

### why 500 is NOT caused by nginx coexistence

envoy gateway and nginx ingress use different loadbalancer IPs. they don't conflict.
the 500 is almost always:
1. argocd in secure mode but httproute points to port 80
2. backend tls validation failing

---

## argocd deployment via argocd (gitops)

### multi-source application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: envoy-gateway-argocd
  namespace: argocd
spec:
  project: platform
  sources:
    - repoURL: oci://docker.io/envoyproxy/gateway-helm
      chart: gateway-helm
      targetRevision: v1.2.0
      helm:
        releaseName: envoy-gateway
        valueFiles:
          - $values/envoy-gateway/values.yaml

    - repoURL: https://gitlab.example.com/platform/gateway-config.git
      targetRevision: main
      ref: values
      path: argocd-envoy

  destination:
    server: https://kubernetes.default.svc
    namespace: envoy-gateway-system

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### app-of-apps with sync waves

```yaml
# wave 0: envoy gateway controller
# wave 1: gatewayclass
# wave 2: gateway + routes + policies
```

ordering matters because:
- gatewayclass must exist before gateway
- gateway must exist before routes
- secrets must exist before gateway (for tls)
