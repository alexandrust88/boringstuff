# envoy gateway - migration guide

patterns for migrating from ingress controllers (nginx, traefik) to envoy gateway using gateway api.

---

## ingress to httproute conversion

### basic conversion

**original ingress:**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-server
  namespace: app-ns
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - app.example.com
      secretName: app-tls
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-server
                port:
                  number: 443
```

**equivalent httproute:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app-server
  namespace: app-ns
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "app.example.com"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: app-server
          port: 80                # use HTTP port, tls terminates at gateway
```

### key differences

| aspect | ingress | httproute |
|--------|---------|-----------|
| tls config | in ingress spec | in gateway listener |
| backend protocol | annotation-based | automatic or BackendTLSPolicy |
| class selection | ingressClassName | parentRefs to Gateway |
| path matching | pathType field | matches.path.type |
| grpc support | annotation hacks | native GRPCRoute |
| rate limiting | annotation | SecurityPolicy CRD |
| redirects | annotation | filters in httproute |
| cors | annotation | SecurityPolicy CRD |

### common nginx annotation mappings

| nginx annotation | gateway api equivalent |
|------------------|----------------------|
| `ssl-redirect: "true"` | separate httproute with RequestRedirect filter |
| `backend-protocol: "HTTPS"` | BackendTLSPolicy |
| `proxy-read-timeout` | BackendTrafficPolicy.timeout.http.requestTimeout |
| `proxy-connect-timeout` | BackendTrafficPolicy.timeout.tcp.connectTimeout |
| `proxy-body-size` | ClientTrafficPolicy (not directly - use envoy filter) |
| `limit-rps` | SecurityPolicy.rateLimit |
| `enable-cors` | SecurityPolicy.cors |
| `auth-url` | SecurityPolicy.extAuth |
| `whitelist-source-range` | SecurityPolicy.authorization.rules |
| `upstream-hash-by` | BackendTrafficPolicy.loadBalancer |
| `server-snippet` | no equivalent (use envoy filters or policies) |

---

## migration strategy

### phased approach for multi-cluster (60+ clusters)

#### phase 1: pilot (2-3 non-critical clusters)

- install envoy gateway alongside existing ingress controller
- deploy httproutes with temporary hostnames for testing
- validate tls, grpc, health checks
- document issues and solutions

#### phase 2: early adopters (10% of clusters)

- apply lessons from pilot
- validate automation scripts
- establish success metrics and monitoring

#### phase 3: majority (70% of clusters)

- use automated rollout (batch 5 at a time)
- batch by region/environment
- monitor aggregate metrics

#### phase 4: laggards (remaining clusters)

- handle special cases
- address remaining issues
- decommission old ingress controller

### parallel running strategy

both ingress and gateway api can coexist - they are different resource types using different loadbalancer IPs.

```
existing ingress controller (keep running)
  -> serves: argocd.old.example.com (or same hostname via current DNS)
  -> LB IP: 20.x.x.1

envoy gateway (new, deploy alongside)
  -> serves: argocd.example.com (via temporary or same hostname)
  -> LB IP: 20.x.x.2
```

#### step 1: deploy httproute alongside ingress

```bash
# existing ingress stays untouched
kubectl get ingress app-server -n app-ns

# deploy new httproute
kubectl apply -f app-httproute.yaml

# both now active, different IPs
kubectl get httproute app-server -n app-ns
```

#### step 2: test with host header or /etc/hosts

```bash
# get gateway IP
GW_IP=$(kubectl get gateway main-gateway -n envoy-gateway-system -o jsonpath='{.status.addresses[0].value}')

# test without changing DNS
curl -v --resolve app.example.com:443:$GW_IP https://app.example.com/

# test tls
echo | openssl s_client -connect $GW_IP:443 -servername app.example.com 2>/dev/null | openssl x509 -text -noout | head -20
```

#### step 3: weighted dns cutover

| day | ingress weight | gateway weight | notes |
|-----|----------------|----------------|-------|
| 1 | 90 | 10 | initial deployment |
| 2 | 75 | 25 | if no issues |
| 3 | 50 | 50 | equal split |
| 4 | 25 | 75 | gateway preferred |
| 5 | 0 | 100 | full cutover |

#### step 4: cleanup

```bash
# only after successful validation and stable operation
kubectl delete ingress app-server -n app-ns
```

---

## dns cutover process

### pre-cutover (24-48h before)

lower dns ttl to 60 seconds for faster failover:

```bash
# example with route53
aws route53 change-resource-record-sets --hosted-zone-id ZONE_ID --change-batch '{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "app.example.com",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "'$CURRENT_IP'"}]
    }
  }]
}'
```

### cutover

```bash
GATEWAY_IP=$(kubectl get gateway main-gateway -n envoy-gateway-system -o jsonpath='{.status.addresses[0].value}')

# update DNS to point to gateway
# (adjust for your DNS provider: route53, cloudflare, azure dns, etc.)
```

### post-cutover validation

```bash
# verify dns propagation
dig app.example.com +short

# test https
curl -I https://app.example.com/healthz

# test grpc (if applicable)
grpcurl -insecure app.example.com:443 list

# restore normal ttl after 24-48h stable operation
```

---

## rollback procedures

### immediate dns rollback

```bash
# point DNS back to ingress controller IP
# ttl is already low (60s) so propagation is fast
```

### httproute rollback

```bash
# delete httproute to ensure no traffic goes to gateway
kubectl delete httproute app-server -n app-ns

# verify ingress still works
kubectl get ingress app-server -n app-ns
curl -I https://app.example.com/healthz
```

### rollback decision criteria

| issue | severity | action |
|-------|----------|--------|
| ui inaccessible | critical | immediate dns rollback |
| grpc/cli not working | high | investigate, rollback if >5 min |
| tls errors | high | check certs, rollback if invalid |
| 5xx errors >1% | medium | investigate, consider rollback |
| latency increase >200% | medium | monitor, rollback if persists |

---

## validation scripts

### pre-migration

```bash
#!/bin/bash
echo "=== pre-migration validation ==="

# gateway ready
echo "1. checking gateway..."
kubectl get gateway main-gateway -n envoy-gateway-system -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}'

# gatewayclass exists
echo "2. checking gatewayclass..."
kubectl get gatewayclass eg

# tls secret exists
echo "3. checking tls secret..."
kubectl get secret app-tls -n <ns>

# backend healthy
echo "4. checking backend..."
kubectl get pods -n <backend-ns> -l <backend-labels>
```

### post-migration

```bash
#!/bin/bash
echo "=== post-migration validation ==="

# httproute accepted
echo "1. httproute status..."
kubectl get httproute <name> -n <ns> -o jsonpath='{.status.parents[0].conditions}' | jq .

# https works
echo "2. testing https..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://<hostname>/healthz)
echo "   status: $HTTP_STATUS"

# grpc works (if applicable)
echo "3. testing grpc..."
grpcurl -insecure <hostname>:443 list

# api works
echo "4. testing api..."
curl -s https://<hostname>/api/version | jq .

# no errors in logs
echo "5. checking logs..."
kubectl logs -n <backend-ns> -l <backend-labels> --tail=50 | grep -i error || echo "   no errors"
```

---

## batch rollout automation

```bash
#!/bin/bash
# batch-rollout.sh

CLUSTERS_FILE="clusters.txt"
BATCH_SIZE=5
WAIT_BETWEEN_BATCHES=3600  # 1 hour

count=0
while IFS= read -r cluster; do
    echo "migrating cluster: $cluster"

    kubectl config use-context "$cluster"
    kubectl apply -f app-httproute.yaml

    ./validate-post-migration.sh
    if [ $? -ne 0 ]; then
        echo "FAILED: $cluster - stopping rollout"
        exit 1
    fi

    ((count++))

    if [ $((count % BATCH_SIZE)) -eq 0 ]; then
        echo "batch complete. waiting ${WAIT_BETWEEN_BATCHES}s..."
        sleep $WAIT_BETWEEN_BATCHES
    fi
done < "$CLUSTERS_FILE"
```
