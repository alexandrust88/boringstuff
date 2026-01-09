# Envoy Gateway Operations Guide

This document covers day-2 operations for managing Envoy Gateway across 60+ AKS clusters, including monitoring, troubleshooting, scaling, certificate management, and log analysis.

---

## Table of Contents

1. [Monitoring and Metrics](#monitoring-and-metrics)
2. [Alerting Strategy](#alerting-strategy)
3. [Troubleshooting Common Issues](#troubleshooting-common-issues)
4. [Scaling Considerations](#scaling-considerations)
5. [Certificate Management](#certificate-management)
6. [Log Analysis](#log-analysis)
7. [Upgrade Procedures](#upgrade-procedures)
8. [Backup and Recovery](#backup-and-recovery)
9. [Runbooks](#runbooks)

---

## Monitoring and Metrics

### Metrics Architecture

```
+------------------------------------------------------------------+
|                        Envoy Proxy Pod                           |
|                                                                  |
|  +------------------+         +------------------+               |
|  | Envoy Process    |         | Admin Interface  |               |
|  |                  |-------->| :19001/stats     |               |
|  +------------------+         +--------+---------+               |
|                                        |                         |
+------------------------------------------------------------------+
                                         |
                                         | Prometheus scrape
                                         v
+------------------------------------------------------------------+
|                     Prometheus                                   |
|  +------------------------------------------------------------+  |
|  | envoy_* metrics                                            |  |
|  | - envoy_cluster_upstream_rq_total                          |  |
|  | - envoy_http_downstream_rq_total                           |  |
|  | - envoy_cluster_upstream_cx_active                         |  |
|  +------------------------------------------------------------+  |
+------------------------------------------------------------------+
                                         |
                                         v
+------------------------------------------------------------------+
|                      Grafana Dashboards                          |
|  - Request rate, latency, error rate                             |
|  - Connection pools                                              |
|  - Circuit breaker status                                        |
+------------------------------------------------------------------+
```

### Prometheus Configuration

#### ServiceMonitor for Envoy Proxy

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: envoy-gateway-proxy
  namespace: monitoring
  labels:
    app: envoy-gateway
spec:
  selector:
    matchLabels:
      gateway.envoyproxy.io/owning-gateway-namespace: argocd
  namespaceSelector:
    matchNames:
      - envoy-gateway-system
  endpoints:
    - port: metrics
      path: /stats/prometheus
      interval: 15s
      scrapeTimeout: 10s
      relabelings:
        - sourceLabels: [__meta_kubernetes_pod_label_gateway_envoyproxy_io_owning_gateway_name]
          targetLabel: gateway
        - sourceLabels: [__meta_kubernetes_namespace]
          targetLabel: namespace
```

#### ServiceMonitor for Envoy Gateway Controller

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: envoy-gateway-controller
  namespace: monitoring
spec:
  selector:
    matchLabels:
      control-plane: envoy-gateway
  namespaceSelector:
    matchNames:
      - envoy-gateway-system
  endpoints:
    - port: metrics
      path: /metrics
      interval: 30s
```

### Key Metrics Reference

#### Request Metrics

| Metric | Description | Labels |
|--------|-------------|--------|
| `envoy_http_downstream_rq_total` | Total requests received | `envoy_http_conn_manager_prefix`, `envoy_response_code` |
| `envoy_http_downstream_rq_xx` | Requests by status class | `envoy_http_conn_manager_prefix` |
| `envoy_http_downstream_rq_time_bucket` | Request latency histogram | `envoy_http_conn_manager_prefix` |
| `envoy_http_downstream_cx_total` | Total connections | `envoy_http_conn_manager_prefix` |
| `envoy_http_downstream_cx_active` | Active connections | `envoy_http_conn_manager_prefix` |

#### Upstream (Backend) Metrics

| Metric | Description | Labels |
|--------|-------------|--------|
| `envoy_cluster_upstream_rq_total` | Requests to backends | `envoy_cluster_name` |
| `envoy_cluster_upstream_rq_time_bucket` | Backend response time | `envoy_cluster_name` |
| `envoy_cluster_upstream_cx_active` | Active backend connections | `envoy_cluster_name` |
| `envoy_cluster_upstream_cx_connect_fail` | Backend connection failures | `envoy_cluster_name` |
| `envoy_cluster_upstream_rq_retry` | Retry count | `envoy_cluster_name` |
| `envoy_cluster_upstream_rq_pending_overflow` | Requests dropped (circuit breaker) | `envoy_cluster_name` |

#### Circuit Breaker Metrics

| Metric | Description | Labels |
|--------|-------------|--------|
| `envoy_cluster_circuit_breakers_default_cx_open` | Connection limit reached | `envoy_cluster_name` |
| `envoy_cluster_circuit_breakers_default_rq_open` | Request limit reached | `envoy_cluster_name` |
| `envoy_cluster_circuit_breakers_default_rq_pending_open` | Pending request limit reached | `envoy_cluster_name` |
| `envoy_cluster_circuit_breakers_default_rq_retry_open` | Retry limit reached | `envoy_cluster_name` |

#### Health Check Metrics

| Metric | Description | Labels |
|--------|-------------|--------|
| `envoy_cluster_health_check_healthy` | Healthy backends count | `envoy_cluster_name` |
| `envoy_cluster_health_check_failure` | Health check failures | `envoy_cluster_name` |
| `envoy_cluster_membership_healthy` | Healthy cluster members | `envoy_cluster_name` |
| `envoy_cluster_membership_total` | Total cluster members | `envoy_cluster_name` |

### Grafana Dashboard

#### Essential Panels

```json
{
  "panels": [
    {
      "title": "Request Rate",
      "type": "graph",
      "targets": [
        {
          "expr": "sum(rate(envoy_http_downstream_rq_total{gateway=\"argocd-gateway\"}[5m])) by (envoy_response_code)",
          "legendFormat": "{{envoy_response_code}}"
        }
      ]
    },
    {
      "title": "P99 Latency",
      "type": "graph",
      "targets": [
        {
          "expr": "histogram_quantile(0.99, sum(rate(envoy_http_downstream_rq_time_bucket{gateway=\"argocd-gateway\"}[5m])) by (le))",
          "legendFormat": "P99"
        }
      ]
    },
    {
      "title": "Error Rate",
      "type": "graph",
      "targets": [
        {
          "expr": "sum(rate(envoy_http_downstream_rq_xx{gateway=\"argocd-gateway\",envoy_response_code_class=\"5\"}[5m])) / sum(rate(envoy_http_downstream_rq_total{gateway=\"argocd-gateway\"}[5m])) * 100",
          "legendFormat": "5xx Error Rate %"
        }
      ]
    },
    {
      "title": "Active Connections",
      "type": "stat",
      "targets": [
        {
          "expr": "sum(envoy_http_downstream_cx_active{gateway=\"argocd-gateway\"})",
          "legendFormat": "Active"
        }
      ]
    },
    {
      "title": "Circuit Breaker Status",
      "type": "stat",
      "targets": [
        {
          "expr": "sum(envoy_cluster_circuit_breakers_default_rq_open{envoy_cluster_name=~\".*argocd.*\"}) > 0",
          "legendFormat": "CB Open"
        }
      ]
    },
    {
      "title": "Backend Health",
      "type": "gauge",
      "targets": [
        {
          "expr": "sum(envoy_cluster_membership_healthy{envoy_cluster_name=~\".*argocd.*\"}) / sum(envoy_cluster_membership_total{envoy_cluster_name=~\".*argocd.*\"}) * 100",
          "legendFormat": "Healthy %"
        }
      ]
    }
  ]
}
```

---

## Alerting Strategy

### Critical Alerts (PagerDuty)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: envoy-gateway-critical
  namespace: monitoring
spec:
  groups:
    - name: envoy-gateway.critical
      rules:
        # No healthy Envoy pods
        - alert: EnvoyGatewayDown
          expr: |
            sum(up{job="envoy-gateway-proxy"}) == 0
          for: 2m
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "Envoy Gateway is down"
            description: "No Envoy proxy pods are responding to metrics scrapes"
            runbook_url: "https://wiki.example.com/runbooks/envoy-gateway-down"

        # High error rate
        - alert: EnvoyGatewayHighErrorRate
          expr: |
            (
              sum(rate(envoy_http_downstream_rq_xx{envoy_response_code_class="5"}[5m]))
              /
              sum(rate(envoy_http_downstream_rq_total[5m]))
            ) > 0.05
          for: 5m
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "Envoy Gateway error rate > 5%"
            description: "{{ $value | humanizePercentage }} of requests are returning 5xx errors"

        # All backends unhealthy
        - alert: EnvoyGatewayAllBackendsUnhealthy
          expr: |
            envoy_cluster_membership_healthy == 0
            and envoy_cluster_membership_total > 0
          for: 1m
          labels:
            severity: critical
            team: platform
          annotations:
            summary: "All backends unhealthy for {{ $labels.envoy_cluster_name }}"
            description: "No healthy backends available, traffic will fail"
```

### Warning Alerts (Slack)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: envoy-gateway-warning
  namespace: monitoring
spec:
  groups:
    - name: envoy-gateway.warning
      rules:
        # High latency
        - alert: EnvoyGatewayHighLatency
          expr: |
            histogram_quantile(0.99,
              sum(rate(envoy_http_downstream_rq_time_bucket[5m])) by (le, gateway)
            ) > 5000
          for: 10m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "P99 latency > 5s for {{ $labels.gateway }}"
            description: "Current P99: {{ $value | humanizeDuration }}"

        # Circuit breaker triggered
        - alert: EnvoyGatewayCircuitBreakerOpen
          expr: |
            envoy_cluster_circuit_breakers_default_rq_open > 0
          for: 5m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "Circuit breaker open for {{ $labels.envoy_cluster_name }}"
            description: "Backend is being protected by circuit breaker"

        # High connection count
        - alert: EnvoyGatewayHighConnectionCount
          expr: |
            envoy_http_downstream_cx_active > 8000
          for: 5m
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "High connection count on {{ $labels.gateway }}"
            description: "{{ $value }} active connections (threshold: 8000)"

        # Certificate expiring soon
        - alert: EnvoyGatewayCertExpiringSoon
          expr: |
            envoy_server_days_until_first_cert_expiring < 14
          for: 1h
          labels:
            severity: warning
            team: platform
          annotations:
            summary: "TLS certificate expiring in {{ $value }} days"
            description: "Certificate for {{ $labels.gateway }} expires soon"
```

---

## Troubleshooting Common Issues

### Issue 1: Gateway Not Accepting Traffic

**Symptoms:**
- curl returns connection refused
- Service has External IP but no response

**Diagnostic Steps:**

```bash
# 1. Check Gateway status
kubectl get gateway argocd-gateway -n argocd -o yaml | grep -A 20 status

# 2. Check if Envoy pods exist and are ready
kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=argocd-gateway

# 3. Check Envoy pod logs
kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=argocd-gateway --tail=100

# 4. Check Service and endpoints
kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=argocd-gateway
kubectl get endpoints -n envoy-gateway-system

# 5. Test from inside cluster
kubectl run debug --rm -it --image=curlimages/curl -- curl -v http://<envoy-pod-ip>:8080/healthz

# 6. Check Envoy config is loaded
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/config_dump | jq '.configs[].dynamic_listeners'
```

**Common Causes:**
| Cause | Solution |
|-------|----------|
| GatewayClass not found | Install Envoy Gateway or check GatewayClass name |
| TLS secret missing | Create secret or fix certificateRef |
| Service selector mismatch | Check labels on Envoy pods |
| xDS connection failed | Check controller logs, network policies |

### Issue 2: HTTPRoute Not Working

**Symptoms:**
- Gateway accepts traffic but routes return 404
- Specific path/host not routing correctly

**Diagnostic Steps:**

```bash
# 1. Check HTTPRoute status
kubectl get httproute argocd-server -n argocd -o yaml | grep -A 30 status

# 2. Verify parentRef is correct
kubectl get httproute argocd-server -n argocd -o jsonpath='{.spec.parentRefs}'

# 3. Check if route is attached to Gateway
kubectl get gateway argocd-gateway -n argocd -o yaml | grep -A 50 'listeners:' | grep -A 10 'attachedRoutes'

# 4. Verify backend service exists
kubectl get svc argocd-server -n argocd

# 5. Check Envoy route configuration
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/config_dump | jq '.configs[] | select(.["@type"] | contains("RoutesConfigDump"))'

# 6. Check for conflicting routes
kubectl get httproute -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,HOSTNAMES:.spec.hostnames'
```

**Common Causes:**
| Cause | Solution |
|-------|----------|
| Wrong parentRef namespace | Add namespace to parentRef |
| Hostname mismatch | Check hostnames in route vs Gateway listener |
| allowedRoutes restriction | Update Gateway listener allowedRoutes |
| Backend service wrong port | Verify service port matches backendRef |

### Issue 3: High Latency

**Symptoms:**
- P99 latency significantly higher than expected
- Timeouts occurring

**Diagnostic Steps:**

```bash
# 1. Check backend response time (upstream_rq_time)
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/stats | grep upstream_rq_time

# 2. Check connection pool stats
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/stats | grep 'cx_active\|cx_connect_ms'

# 3. Check retry stats
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/stats | grep retry

# 4. Check for circuit breaker activity
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/stats | grep circuit

# 5. Check backend pod resource usage
kubectl top pods -n argocd -l app.kubernetes.io/name=argocd-server

# 6. Check for DNS resolution delays
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/stats | grep dns
```

**Common Causes:**
| Cause | Solution |
|-------|----------|
| Backend slow | Scale backend, optimize code |
| Connection pool exhaustion | Increase circuit breaker limits |
| DNS resolution | Use headless service, DNS caching |
| TLS handshake overhead | Enable connection pooling, keepalive |
| Retries adding latency | Tune retry settings |

### Issue 4: Certificate Issues

**Symptoms:**
- HTTPS connections fail with certificate errors
- Browser shows certificate warning

**Diagnostic Steps:**

```bash
# 1. Check TLS secret exists and has data
kubectl get secret argocd-server-tls -n argocd -o yaml | grep -E 'tls.crt|tls.key'

# 2. Verify certificate content
kubectl get secret argocd-server-tls -n argocd -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | head -20

# 3. Check certificate expiry
kubectl get secret argocd-server-tls -n argocd -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -enddate -noout

# 4. Check Gateway TLS config
kubectl get gateway argocd-gateway -n argocd -o yaml | grep -A 10 'tls:'

# 5. Test TLS from outside
openssl s_client -connect argocd.platform.example.com:443 -servername argocd.platform.example.com < /dev/null 2>/dev/null | openssl x509 -text -noout | head -20

# 6. Check Envoy certificate stats
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/stats | grep ssl
```

### Issue 5: gRPC Not Working (ArgoCD CLI)

**Symptoms:**
- `argocd login` fails
- gRPC-specific errors

**Diagnostic Steps:**

```bash
# 1. Test gRPC connectivity
grpcurl -insecure argocd.platform.example.com:443 list

# 2. Check HTTP/2 is enabled
curl -v --http2 https://argocd.platform.example.com/ 2>&1 | grep -i 'http/2\|alpn'

# 3. Verify GRPCRoute exists and is accepted
kubectl get grpcroute -n argocd -o yaml | grep -A 20 status

# 4. Check ClientTrafficPolicy for HTTP/2
kubectl get clienttrafficpolicy -n argocd -o yaml | grep -A 10 'http2:'

# 5. Check Envoy HTTP/2 stats
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/stats | grep 'http2\|downstream_cx_http2'

# 6. Test with grpc-web fallback
argocd login argocd.platform.example.com --grpc-web --insecure
```

**Solution Checklist:**
- [ ] ClientTrafficPolicy with HTTP/2 enabled
- [ ] GRPCRoute or HTTPRoute with HTTP/2 backend
- [ ] ArgoCD server running in insecure mode (TLS at gateway)
- [ ] Correct port (usually 443 with TLS termination)

---

## Scaling Considerations

### Horizontal Scaling

#### Envoy Proxy Pods

```yaml
# Scale based on load
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: scalable-proxy
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        replicas: 3  # Minimum for production

        # Optional: HPA configuration
        # Note: Envoy Gateway doesn't natively support HPA,
        # but you can create one manually
```

**Manual HPA for Envoy Pods:**

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: envoy-argocd-gateway
  namespace: envoy-gateway-system
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: envoy-argocd-gateway-xxx  # Get actual name from cluster
  minReplicas: 3
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Pods
      pods:
        metric:
          name: envoy_http_downstream_cx_active
        target:
          type: AverageValue
          averageValue: "1000"
```

#### Controller Scaling

The Envoy Gateway controller uses leader election, so only one pod is active:

```yaml
# Scale controller for HA (standby replicas)
deployment:
  envoyGateway:
    replicas: 2  # 1 leader + 1 standby
```

### Vertical Scaling

#### Resource Recommendations by Load

| Traffic Level | Envoy CPU Request | Envoy Memory Request | Envoy Replicas |
|---------------|-------------------|----------------------|----------------|
| Low (<1k RPS) | 100m | 128Mi | 2 |
| Medium (1-5k RPS) | 250m | 256Mi | 3 |
| High (5-20k RPS) | 500m | 512Mi | 5 |
| Very High (>20k RPS) | 1000m | 1Gi | 10+ |

```yaml
# Example for high-traffic gateway
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        replicas: 5
        container:
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: 2000m
              memory: 2Gi
```

### Connection and Request Limits

```yaml
# Tune circuit breaker for high concurrency
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: high-concurrency
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: high-traffic-app
  circuitBreaker:
    maxConnections: 10000        # Per-pod limit
    maxPendingRequests: 10000
    maxRequests: 10000
    maxRetries: 10
```

---

## Certificate Management

### Option 1: cert-manager Integration (Recommended)

```yaml
# Install cert-manager and configure ClusterIssuer
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: platform@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: platform-gateway
                namespace: envoy-gateway-system
                kind: Gateway

---
# Certificate for ArgoCD
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-server-tls
  namespace: argocd
spec:
  secretName: argocd-server-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - argocd.platform.example.com
  duration: 2160h    # 90 days
  renewBefore: 720h  # 30 days
```

### Option 2: External Certificate (Wildcard)

```bash
# Import existing certificate
kubectl create secret tls wildcard-platform-tls \
  -n envoy-gateway-system \
  --cert=./fullchain.pem \
  --key=./privkey.pem
```

### Certificate Rotation Monitoring

```yaml
# Alert on expiring certificates
- alert: TLSCertificateExpiringSoon
  expr: |
    envoy_server_days_until_first_cert_expiring < 14
  for: 1h
  labels:
    severity: warning
  annotations:
    summary: "Certificate expiring in {{ $value }} days"
```

### Rotation Procedure (Manual)

```bash
# 1. Create new secret with updated certificate
kubectl create secret tls argocd-server-tls-new \
  -n argocd \
  --cert=./new-cert.pem \
  --key=./new-key.pem

# 2. Update Gateway to use new secret
kubectl patch gateway argocd-gateway -n argocd --type='json' \
  -p='[{"op": "replace", "path": "/spec/listeners/1/tls/certificateRefs/0/name", "value": "argocd-server-tls-new"}]'

# 3. Verify new certificate is served
openssl s_client -connect argocd.platform.example.com:443 -servername argocd.platform.example.com < /dev/null 2>/dev/null | openssl x509 -dates -noout

# 4. Clean up old secret (after verification)
kubectl delete secret argocd-server-tls -n argocd

# 5. Rename new secret (optional, for consistency)
# Note: Secrets cannot be renamed, would need to recreate
```

---

## Log Analysis

### Access Log Configuration

```yaml
# Enable JSON access logging
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: logging-config
  namespace: envoy-gateway-system
spec:
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
              upstream_host: "%UPSTREAM_HOST%"
              upstream_cluster: "%UPSTREAM_CLUSTER%"
              grpc_status: "%GRPC_STATUS%"
          sinks:
            - type: File
              file:
                path: /dev/stdout
```

### Log Query Examples (Loki/Grafana)

```logql
# All 5xx errors
{namespace="envoy-gateway-system", container="envoy"} |= "response_code" | json | response_code >= 500

# Slow requests (>5s)
{namespace="envoy-gateway-system", container="envoy"} | json | duration > 5000

# Failed health checks
{namespace="envoy-gateway-system", container="envoy"} |= "health_check" |= "failure"

# Requests to specific path
{namespace="envoy-gateway-system", container="envoy"} | json | path =~ "/api/v1/.*"

# gRPC errors
{namespace="envoy-gateway-system", container="envoy"} | json | grpc_status != "" and grpc_status != "0"

# Top 10 slowest requests
{namespace="envoy-gateway-system", container="envoy"} | json | line_format "{{.duration}}ms {{.method}} {{.path}}" | topk(10, duration)
```

### Response Flags Reference

| Flag | Meaning | Investigation |
|------|---------|---------------|
| `UH` | No healthy upstream | Check backend pods |
| `UF` | Upstream connection failure | Check backend service, network |
| `UO` | Upstream overflow (circuit breaker) | Increase limits or scale backend |
| `UT` | Upstream timeout | Increase timeout or optimize backend |
| `NR` | No route configured | Check HTTPRoute |
| `URX` | Upstream retry limit exceeded | Check retry config |
| `DC` | Downstream connection termination | Client closed connection |
| `DPE` | Downstream protocol error | Client protocol issue |
| `RL` | Rate limited | Expected if rate limiting enabled |
| `UAEX` | Unauthorized (external auth) | Check auth configuration |

---

## Upgrade Procedures

### Pre-Upgrade Checklist

- [ ] Review release notes for breaking changes
- [ ] Test upgrade in staging environment
- [ ] Verify backup of Gateway resources
- [ ] Schedule maintenance window
- [ ] Notify stakeholders

### Upgrade Steps

```bash
# 1. Backup current configuration
kubectl get gateway,httproute,grpcroute,backendtrafficpolicy,clienttrafficpolicy,securitypolicy -A -o yaml > envoy-gateway-backup-$(date +%Y%m%d).yaml

# 2. Check current version
helm list -n envoy-gateway-system

# 3. Update Gateway API CRDs (if required)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

# 4. Upgrade Envoy Gateway
helm upgrade envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version v1.2.0 \
  --namespace envoy-gateway-system \
  --reuse-values \
  --wait

# 5. Verify controller is running
kubectl get pods -n envoy-gateway-system -l control-plane=envoy-gateway

# 6. Verify data plane rolled out (if pod template changed)
kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name

# 7. Test functionality
curl -v https://argocd.platform.example.com/healthz
argocd login argocd.platform.example.com --grpc-web --insecure

# 8. Monitor for errors
kubectl logs -n envoy-gateway-system -l control-plane=envoy-gateway --tail=100 -f
```

### Rollback Procedure

```bash
# 1. Rollback Helm release
helm rollback envoy-gateway -n envoy-gateway-system

# 2. If CRDs were updated, restore from backup
kubectl apply -f envoy-gateway-backup-YYYYMMDD.yaml

# 3. Force restart of controller
kubectl rollout restart deployment -n envoy-gateway-system envoy-gateway

# 4. Verify
kubectl get pods -n envoy-gateway-system
```

---

## Backup and Recovery

### What to Backup

| Resource | Frequency | Method |
|----------|-----------|--------|
| Gateway resources | Daily + before changes | GitOps (ArgoCD) |
| TLS secrets | On creation/rotation | Vault/external KMS |
| EnvoyProxy config | On change | GitOps |
| Helm values | On change | GitOps |

### GitOps Backup (ArgoCD)

All Gateway resources should be in Git and managed by ArgoCD:

```
envoy-gateway-argocd/
├── base/
│   ├── gateway.yaml
│   ├── httproutes.yaml
│   ├── policies.yaml
│   └── kustomization.yaml
└── overlays/
    ├── prod/
    │   ├── gateway-patch.yaml
    │   └── kustomization.yaml
    └── staging/
        ├── gateway-patch.yaml
        └── kustomization.yaml
```

### Disaster Recovery

```bash
# Scenario: Complete cluster loss, need to restore Envoy Gateway

# 1. Ensure Public IP still exists in Azure
az network public-ip show -g rg-networking-prod -n pip-envoy-gateway-prod

# 2. Install Gateway API CRDs
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

# 3. Install Envoy Gateway
helm install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version v1.2.0 \
  --namespace envoy-gateway-system \
  --create-namespace \
  -f values.yaml

# 4. Restore TLS secrets from Vault/backup
kubectl create secret tls argocd-server-tls -n argocd \
  --cert=./fullchain.pem --key=./privkey.pem

# 5. Apply Gateway resources (via ArgoCD sync or manual)
argocd app sync envoy-gateway-config

# 6. Verify IP was attached
kubectl get svc -n envoy-gateway-system

# 7. DNS should already point to static IP - test
curl https://argocd.platform.example.com/healthz
```

---

## Runbooks

### Runbook: Gateway Not Responding

**Trigger:** Alert `EnvoyGatewayDown` or user report

```
1. CHECK: Are Envoy pods running?
   kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name

   If NO pods:
     - Check Gateway status: kubectl get gateway -A
     - Check controller logs: kubectl logs -n envoy-gateway-system -l control-plane=envoy-gateway
     - May need to recreate Gateway resource

   If pods exist but not Ready:
     - Check pod events: kubectl describe pod <pod-name>
     - Check container logs: kubectl logs <pod-name>

2. CHECK: Is Service getting traffic?
   kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name

   If no External IP:
     - Check Azure annotations are correct
     - Verify Public IP exists in Azure
     - Check AKS managed identity permissions

3. CHECK: Are backends healthy?
   kubectl exec <envoy-pod> -- wget -qO- localhost:19001/clusters | grep health

   If unhealthy:
     - Check backend pods: kubectl get pods -n <backend-ns>
     - Check backend service: kubectl get endpoints -n <backend-ns>

4. ESCALATE: If above checks pass but still not working
   - Check Azure Load Balancer in portal
   - Check NSG rules
   - Check for Azure outage: status.azure.com
```

### Runbook: High Error Rate

**Trigger:** Alert `EnvoyGatewayHighErrorRate`

```
1. IDENTIFY: Which status codes?
   kubectl exec <envoy-pod> -- wget -qO- localhost:19001/stats | grep downstream_rq_

   503: Backend unavailable
   504: Backend timeout
   429: Rate limited
   401/403: Auth issues

2. For 503/504:
   - Check backend health: kubectl get pods -n <backend-ns>
   - Check circuit breaker: kubectl exec <envoy-pod> -- wget -qO- localhost:19001/stats | grep circuit
   - May need to scale backend or adjust circuit breaker

3. For 429:
   - Check rate limit config in BackendTrafficPolicy
   - Verify if legitimate traffic spike or attack
   - Adjust limits if needed

4. For 401/403:
   - Check SecurityPolicy configuration
   - Verify JWT/OIDC provider is healthy
   - Check IP allowlist if configured
```

---

## Related Documentation

- [README.md](./README.md) - Overview
- [ARCHITECTURE.md](./ARCHITECTURE.md) - Architecture details
- [AZURE-INTEGRATION.md](./AZURE-INTEGRATION.md) - Azure configuration
