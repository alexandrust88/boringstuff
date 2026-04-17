# envoy gateway - operations

day-2 operations: monitoring, alerting, troubleshooting, scaling, upgrades, and runbooks.

---

## monitoring

### metrics architecture

envoy proxy exposes prometheus metrics on admin port 19001 at `/stats/prometheus`.
envoy gateway controller exposes metrics at `/metrics`.

### servicemonitor for envoy proxy

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: envoy-gateway-proxy
  namespace: monitoring
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

### servicemonitor for controller

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

### key metrics reference

#### request metrics

| metric | description |
|--------|-------------|
| `envoy_http_downstream_rq_total` | total requests received |
| `envoy_http_downstream_rq_xx` | requests by status class (2xx, 3xx, 4xx, 5xx) |
| `envoy_http_downstream_rq_time_bucket` | request latency histogram |
| `envoy_http_downstream_cx_total` | total connections |
| `envoy_http_downstream_cx_active` | active connections |

#### upstream (backend) metrics

| metric | description |
|--------|-------------|
| `envoy_cluster_upstream_rq_total` | requests to backends |
| `envoy_cluster_upstream_rq_time_bucket` | backend response time |
| `envoy_cluster_upstream_cx_active` | active backend connections |
| `envoy_cluster_upstream_cx_connect_fail` | backend connection failures |
| `envoy_cluster_upstream_rq_retry` | retry count |
| `envoy_cluster_upstream_rq_pending_overflow` | requests dropped (circuit breaker) |

#### circuit breaker metrics

| metric | description |
|--------|-------------|
| `envoy_cluster_circuit_breakers_default_cx_open` | connection limit reached |
| `envoy_cluster_circuit_breakers_default_rq_open` | request limit reached |
| `envoy_cluster_circuit_breakers_default_rq_pending_open` | pending request limit reached |

#### health check metrics

| metric | description |
|--------|-------------|
| `envoy_cluster_health_check_healthy` | healthy backends count |
| `envoy_cluster_health_check_failure` | health check failures |
| `envoy_cluster_membership_healthy` | healthy cluster members |
| `envoy_cluster_membership_total` | total cluster members |

### grafana promql examples

```promql
# request rate by status code
sum(rate(envoy_http_downstream_rq_total{gateway="argocd-gateway"}[5m])) by (envoy_response_code)

# p99 latency
histogram_quantile(0.99, sum(rate(envoy_http_downstream_rq_time_bucket{gateway="argocd-gateway"}[5m])) by (le))

# error rate percentage
sum(rate(envoy_http_downstream_rq_xx{gateway="argocd-gateway",envoy_response_code_class="5"}[5m])) / sum(rate(envoy_http_downstream_rq_total{gateway="argocd-gateway"}[5m])) * 100

# active connections
sum(envoy_http_downstream_cx_active{gateway="argocd-gateway"})

# backend health percentage
sum(envoy_cluster_membership_healthy{envoy_cluster_name=~".*argocd.*"}) / sum(envoy_cluster_membership_total{envoy_cluster_name=~".*argocd.*"}) * 100
```

### loki log queries

```logql
# all 5xx errors
{namespace="envoy-gateway-system", container="envoy"} |= "response_code" | json | response_code >= 500

# slow requests (>5s)
{namespace="envoy-gateway-system", container="envoy"} | json | duration > 5000

# grpc errors
{namespace="envoy-gateway-system", container="envoy"} | json | grpc_status != "" and grpc_status != "0"

# requests to specific path
{namespace="envoy-gateway-system", container="envoy"} | json | path =~ "/api/v1/.*"
```

---

## alerting

### critical alerts (pagerduty)

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
        - alert: EnvoyGatewayDown
          expr: sum(up{job="envoy-gateway-proxy"}) == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "envoy gateway is down - no proxy pods responding"

        - alert: EnvoyGatewayHighErrorRate
          expr: |
            (sum(rate(envoy_http_downstream_rq_xx{envoy_response_code_class="5"}[5m]))
            / sum(rate(envoy_http_downstream_rq_total[5m]))) > 0.05
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "envoy gateway error rate > 5%"

        - alert: EnvoyGatewayAllBackendsUnhealthy
          expr: |
            envoy_cluster_membership_healthy == 0
            and envoy_cluster_membership_total > 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "all backends unhealthy for {{ $labels.envoy_cluster_name }}"
```

### warning alerts (slack)

```yaml
        - alert: EnvoyGatewayHighLatency
          expr: |
            histogram_quantile(0.99,
              sum(rate(envoy_http_downstream_rq_time_bucket[5m])) by (le, gateway)
            ) > 5000
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "p99 latency > 5s for {{ $labels.gateway }}"

        - alert: EnvoyGatewayCircuitBreakerOpen
          expr: envoy_cluster_circuit_breakers_default_rq_open > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "circuit breaker open for {{ $labels.envoy_cluster_name }}"

        - alert: EnvoyGatewayHighConnectionCount
          expr: envoy_http_downstream_cx_active > 8000
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "high connection count: {{ $value }} active"

        - alert: EnvoyGatewayCertExpiringSoon
          expr: envoy_server_days_until_first_cert_expiring < 14
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "tls certificate expiring in {{ $value }} days"
```

---

## troubleshooting

### response flags reference

when analyzing access logs, the `response_flags` field tells you what happened:

| flag | meaning | action |
|------|---------|--------|
| UH | no healthy upstream | check backend pods |
| UF | upstream connection failure | check backend service, network policies |
| UO | upstream overflow (circuit breaker) | increase limits or scale backend |
| UT | upstream timeout | increase timeout or optimize backend |
| NR | no route configured | check httproute |
| URX | upstream retry limit exceeded | check retry config |
| DC | downstream connection termination | client closed connection |
| DPE | downstream protocol error | client protocol issue |
| RL | rate limited | expected if rate limiting enabled |
| UAEX | unauthorized (external auth) | check auth configuration |

### issue: gateway not accepting traffic

symptoms: curl returns connection refused, service has external ip but no response

```bash
# 1. check gateway status
kubectl get gateway <name> -n <ns> -o yaml | grep -A 20 status

# 2. check envoy pods exist and are ready
kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=<gateway>

# 3. check envoy pod logs
kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=<gateway> --tail=100

# 4. check service and endpoints
kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=<gateway>

# 5. test from inside cluster
kubectl run debug --rm -it --image=curlimages/curl -- curl -v http://<envoy-pod-ip>:8080/healthz

# 6. check envoy config is loaded
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/config_dump | jq '.configs[].dynamic_listeners'
```

common causes:
- gatewayclass not found -> install envoy gateway or check gatewayclass name
- tls secret missing -> create secret or fix certificateRef
- service selector mismatch -> check labels on envoy pods
- xds connection failed -> check controller logs, network policies

### issue: httproute not working (404s)

symptoms: gateway accepts traffic but routes return 404

```bash
# 1. check httproute status
kubectl get httproute <name> -n <ns> -o yaml | grep -A 30 status

# 2. verify parentref is correct
kubectl get httproute <name> -n <ns> -o jsonpath='{.spec.parentRefs}'

# 3. check attached routes count on gateway
kubectl get gateway <name> -n <ns> -o yaml | grep -A 50 'listeners:' | grep -A 10 'attachedRoutes'

# 4. verify backend service exists
kubectl get svc <backend-name> -n <ns>

# 5. check envoy route config
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/config_dump | jq '.configs[] | select(.["@type"] | contains("RoutesConfigDump"))'

# 6. check for conflicting routes
kubectl get httproute -A -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,HOSTNAMES:.spec.hostnames'
```

common causes:
- wrong parentref namespace
- hostname mismatch between route and gateway listener
- allowedroutes restriction on gateway
- backend service wrong port

### issue: 500/502/503 errors

```bash
# check response flags in access logs
kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=<gateway> --tail=100 | jq -r '.response_flags'

# check backend health
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/clusters | grep health

# check circuit breaker
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/stats | grep circuit

# check backend pods
kubectl get pods -n <backend-ns> -l <backend-labels>
kubectl get endpoints <backend-svc> -n <backend-ns>
```

for 500 specifically with argocd:
- argocd in secure mode (https only) but httproute points to port 80
- fix: either enable insecure mode or use BackendTLSPolicy

### issue: grpc not working

symptoms: `argocd login` fails, grpc-specific errors

```bash
# test grpc
grpcurl -insecure <hostname>:443 list

# check http/2
curl -v --http2 https://<hostname>/ 2>&1 | grep -i 'http/2\|alpn'

# verify grpcroute is accepted
kubectl get grpcroute -n <ns> -o yaml | grep -A 20 status

# check clienttrafficpolicy for http/2
kubectl get clienttrafficpolicy -n <ns> -o yaml | grep -A 10 'http2:'

# check envoy http/2 stats
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/stats | grep 'http2\|downstream_cx_http2'

# fallback test
argocd login <hostname> --grpc-web --insecure
```

checklist:
- [ ] clienttrafficpolicy with http/2 enabled
- [ ] grpcroute or httproute with http/2 backend
- [ ] argocd server in insecure mode (tls terminates at gateway)
- [ ] correct port (443 with tls termination)

### issue: high latency

```bash
# check backend response time
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/stats | grep upstream_rq_time

# check connection pool
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/stats | grep 'cx_active\|cx_connect_ms'

# check retries (retries add latency)
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/stats | grep retry

# check backend resource usage
kubectl top pods -n <backend-ns> -l <backend-labels>
```

### issue: certificate errors

```bash
# check secret exists
kubectl get secret <tls-secret> -n <ns>

# verify cert content
kubectl get secret <tls-secret> -n <ns> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | head -20

# check expiry
kubectl get secret <tls-secret> -n <ns> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -enddate -noout

# check gateway tls config
kubectl get gateway <name> -n <ns> -o yaml | grep -A 10 'tls:'

# test tls from outside
openssl s_client -connect <hostname>:443 -servername <hostname> < /dev/null 2>/dev/null | openssl x509 -text -noout | head -20

# check envoy ssl stats
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/stats | grep ssl
```

---

## scaling

### horizontal pod autoscaler for envoy

envoy gateway doesn't natively create HPA. create manually:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: envoy-gateway-proxy
  namespace: envoy-gateway-system
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: envoy-<gateway-name>-<hash>    # get actual name from cluster
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

### controller scaling

controller uses leader election - only one pod active:
- replicas: 2 = 1 leader + 1 standby (recommended for HA)
- data plane continues working if controller is down (no config updates though)

---

## upgrade procedure

### pre-upgrade checklist

- [ ] review release notes for breaking changes
- [ ] test upgrade in staging
- [ ] backup gateway resources
- [ ] schedule maintenance window

### upgrade steps

```bash
# 1. backup
kubectl get gateway,httproute,grpcroute,backendtrafficpolicy,clienttrafficpolicy,securitypolicy -A -o yaml > envoy-backup-$(date +%Y%m%d).yaml

# 2. check current version
helm list -n envoy-gateway-system

# 3. update gateway api crds (if required)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

# 4. upgrade
helm upgrade envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version v1.2.0 \
  --namespace envoy-gateway-system \
  --reuse-values \
  --wait

# 5. verify controller
kubectl get pods -n envoy-gateway-system -l control-plane=envoy-gateway

# 6. verify data plane
kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name

# 7. test
curl -v https://<hostname>/healthz
argocd login <hostname> --grpc-web --insecure

# 8. monitor
kubectl logs -n envoy-gateway-system -l control-plane=envoy-gateway --tail=100 -f
```

### rollback

```bash
helm rollback envoy-gateway -n envoy-gateway-system
kubectl apply -f envoy-backup-YYYYMMDD.yaml   # if crds were updated
kubectl rollout restart deployment -n envoy-gateway-system envoy-gateway
```

---

## runbooks

### runbook: gateway not responding

trigger: alert EnvoyGatewayDown or user report

```
1. are envoy pods running?
   kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name
   NO pods -> check gateway status, check controller logs
   pods not ready -> check pod events, container logs

2. is service getting traffic?
   kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name
   no external ip -> check lb annotations, verify public ip exists

3. are backends healthy?
   kubectl exec <envoy-pod> -- wget -qO- localhost:19001/clusters | grep health
   unhealthy -> check backend pods, check service endpoints

4. escalate if all checks pass but still not working
   check load balancer in cloud provider console
   check nsg/firewall rules
   check for provider outage
```

### runbook: high error rate

trigger: alert EnvoyGatewayHighErrorRate

```
1. identify status codes
   kubectl exec <envoy-pod> -- wget -qO- localhost:19001/stats | grep downstream_rq_

   503: backend unavailable -> check pods, circuit breaker
   504: backend timeout -> check timeouts, backend performance
   429: rate limited -> check rate limit config
   401/403: auth issues -> check security policy

2. for 503/504:
   check backend health
   check circuit breaker stats
   scale backend or adjust circuit breaker limits

3. for 429:
   verify if legitimate traffic or attack
   adjust rate limits if needed

4. for 401/403:
   check securitypolicy
   verify jwt/oidc provider health
```

---

## backup and recovery

### what to backup

| resource | frequency | method |
|----------|-----------|--------|
| gateway resources | daily + before changes | gitops (argocd) |
| tls secrets | on creation/rotation | vault/external kms |
| envoyproxy config | on change | gitops |
| helm values | on change | gitops |

### disaster recovery

```bash
# 1. install gateway api crds
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml

# 2. install envoy gateway
helm install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version v1.2.0 \
  --namespace envoy-gateway-system \
  --create-namespace \
  -f values.yaml

# 3. restore tls secrets
kubectl create secret tls <name> -n <ns> --cert=./fullchain.pem --key=./privkey.pem

# 4. apply gateway resources (argocd sync or manual)
argocd app sync envoy-gateway-config

# 5. verify
kubectl get svc -n envoy-gateway-system
curl https://<hostname>/healthz
```
