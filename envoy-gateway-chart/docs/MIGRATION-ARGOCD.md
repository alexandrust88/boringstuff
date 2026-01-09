# ArgoCD to Envoy Gateway Migration Guide

This guide provides a comprehensive approach to migrating ArgoCD ingress from traditional Kubernetes Ingress resources to Envoy Gateway HTTPRoutes across 60+ clusters.

## Table of Contents

1. [Pre-Migration Checklist](#pre-migration-checklist)
2. [Architecture Overview](#architecture-overview)
3. [Step-by-Step Migration Process](#step-by-step-migration-process)
4. [Converting ArgoCD Ingress to HTTPRoute](#converting-argocd-ingress-to-httproute)
5. [Parallel Running Strategy](#parallel-running-strategy)
6. [DNS Cutover Process](#dns-cutover-process)
7. [Rollback Procedures](#rollback-procedures)
8. [Validation Steps](#validation-steps)
9. [Troubleshooting](#troubleshooting)

---

## Pre-Migration Checklist

### Infrastructure Requirements

- [ ] Envoy Gateway is installed and running in the cluster
- [ ] GatewayClass `envoy-gateway` is available
- [ ] Gateway resource is configured with appropriate listeners (HTTP/HTTPS/gRPC)
- [ ] TLS certificates are available as Kubernetes Secrets
- [ ] DNS records are accessible for modification

### ArgoCD Requirements

- [ ] Document current ArgoCD Ingress configuration
- [ ] Identify all hostnames used by ArgoCD (UI, gRPC, webhook)
- [ ] Note any custom annotations or configurations
- [ ] Verify ArgoCD health checks are properly configured
- [ ] Backup current Ingress manifests

### Access Requirements

- [ ] kubectl access to target clusters
- [ ] DNS management access (Route53, CloudFlare, etc.)
- [ ] Helm/GitOps repository write access
- [ ] Monitoring/alerting system access

### Pre-Migration Testing

- [ ] Test Envoy Gateway HTTPRoute on a non-production cluster
- [ ] Verify TLS termination works correctly
- [ ] Test gRPC connectivity for ArgoCD CLI
- [ ] Validate health check endpoints respond correctly

---

## Architecture Overview

### Current State (Ingress Controller)

```
                    +-------------------+
Internet --> DNS -->| Ingress Controller|
                    | (nginx/traefik)   |
                    +-------------------+
                            |
                    +-------v-------+
                    |   ArgoCD      |
                    | (UI + gRPC)   |
                    +---------------+
```

### Target State (Envoy Gateway)

```
                    +-------------------+
Internet --> DNS -->|  Envoy Gateway   |
                    |   (Gateway API)   |
                    +-------------------+
                            |
                    +-------v-------+
                    |   ArgoCD      |
                    | (UI + gRPC)   |
                    +---------------+
```

### Parallel Running State (During Migration)

```
                         +-------------------+
                    +--->| Ingress Controller| (argocd.old.example.com)
                    |    +-------------------+
Internet --> DNS ---+            |
                    |    +-------v-------+
                    |    |   ArgoCD      |
                    |    | (UI + gRPC)   |
                    |    +---------------+
                    |            ^
                    |    +-------+-------+
                    +--->|  Envoy Gateway | (argocd.example.com)
                         +-------------------+
```

---

## Using the argocd-envoy Chart

A dedicated Helm chart `argocd-envoy` is provided for ArgoCD HTTPRoute configuration. This is the recommended approach for production deployments.

```bash
# Deploy argocd-envoy chart
helm upgrade --install argocd-envoy ../argocd-envoy \
  -f ../argocd-envoy/values.yaml \
  -f ../argocd-envoy/values-prod.yaml \
  -n envoy-gateway-system \
  --set hostname=argocd.example.com \
  --set tls.certificate.issuerRef.name=letsencrypt-prod
```

See `argocd-envoy/README.md` for full configuration options.

---

## Step-by-Step Migration Process

### Phase 1: Preparation

#### Step 1.1: Document Current Configuration

```bash
# Export current ArgoCD ingress configuration
kubectl get ingress -n argocd -o yaml > argocd-ingress-backup.yaml

# Document all annotations
kubectl get ingress argocd-server -n argocd -o jsonpath='{.metadata.annotations}' | jq .

# Document TLS configuration
kubectl get secret -n argocd -l app.kubernetes.io/part-of=argocd
```

#### Step 1.2: Verify Envoy Gateway Readiness

```bash
# Check GatewayClass exists
kubectl get gatewayclass envoy-gateway

# Check Gateway is ready
kubectl get gateway -n envoy-gateway-system

# Verify Gateway has external IP/hostname
kubectl get gateway -n envoy-gateway-system -o jsonpath='{.items[0].status.addresses[0].value}'
```

#### Step 1.3: Prepare TLS Certificates

```bash
# Create or copy TLS secret for Envoy Gateway
kubectl create secret tls argocd-tls \
  --cert=tls.crt \
  --key=tls.key \
  -n envoy-gateway-system

# Or copy existing secret
kubectl get secret argocd-tls -n argocd -o yaml | \
  sed 's/namespace: argocd/namespace: envoy-gateway-system/' | \
  kubectl apply -f -
```

### Phase 2: Deploy HTTPRoute

#### Step 2.1: Create HTTPRoute with Temporary Hostname

Deploy the HTTPRoute with a temporary hostname first to validate without affecting production:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-test
  namespace: argocd
spec:
  parentRefs:
    - name: main-gateway
      namespace: envoy-gateway-system
  hostnames:
    - "argocd-test.example.com"  # Temporary test hostname
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: argocd-server
          port: 80
```

#### Step 2.2: Validate Test HTTPRoute

```bash
# Check HTTPRoute status
kubectl get httproute argocd-test -n argocd -o yaml

# Verify route is accepted
kubectl get httproute argocd-test -n argocd -o jsonpath='{.status.parents[0].conditions}'

# Test connectivity (update /etc/hosts or use curl with Host header)
curl -H "Host: argocd-test.example.com" https://<gateway-ip>/ -k
```

#### Step 2.3: Deploy Production HTTPRoute

Once testing is successful, deploy with production hostname:

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

### Phase 3: Parallel Running

See [Parallel Running Strategy](#parallel-running-strategy) for details.

### Phase 4: DNS Cutover

See [DNS Cutover Process](#dns-cutover-process) for details.

### Phase 5: Cleanup

#### Step 5.1: Remove Old Ingress

```bash
# Only after successful validation
kubectl delete ingress argocd-server -n argocd
kubectl delete ingress argocd-grpc -n argocd  # if separate
```

#### Step 5.2: Update Documentation

- Update runbooks with new routing information
- Update monitoring dashboards
- Update DNS documentation

---

## Converting ArgoCD Ingress to HTTPRoute

### Basic Conversion

**Original Ingress:**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
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
          port: 80  # Use HTTP port, TLS terminates at Gateway
```

### Key Differences

| Aspect | Ingress | HTTPRoute |
|--------|---------|-----------|
| TLS Config | In Ingress spec | In Gateway listener |
| Backend Protocol | Annotation-based | Automatic or BackendTLSPolicy |
| Class Selection | ingressClassName | parentRefs to Gateway |
| Path Matching | pathType field | matches.path.type |

### gRPC Support for ArgoCD CLI

ArgoCD CLI uses gRPC. You need a GRPCRoute or configure HTTP/2:

**Option 1: Use HTTP/2 via HTTPRoute (Recommended)**

The Gateway should be configured to support HTTP/2:

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
```

**Option 2: Separate GRPCRoute**

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
  hostnames:
    - "argocd.example.com"
  rules:
    - backendRefs:
        - name: argocd-server
          port: 443
```

---

## Parallel Running Strategy

Running both ingress solutions simultaneously minimizes risk during migration.

### Strategy Overview

1. **Keep existing Ingress active** - No changes to production traffic
2. **Deploy HTTPRoute with same hostname** - Both will receive traffic based on DNS
3. **Use weighted DNS** - Gradually shift traffic to Envoy Gateway
4. **Monitor both paths** - Compare metrics and error rates

### Implementation Steps

#### Step 1: Deploy HTTPRoute Alongside Ingress

Both can coexist as they're different resource types:

```bash
# Existing Ingress continues to work
kubectl get ingress argocd-server -n argocd

# Deploy new HTTPRoute
kubectl apply -f argocd-httproute.yaml

# Both are now active
kubectl get httproute argocd-server -n argocd
```

#### Step 2: Configure Weighted DNS

Using Route53 as an example:

```bash
# Get both endpoints
INGRESS_LB=$(kubectl get ingress argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
GATEWAY_LB=$(kubectl get gateway main-gateway -n envoy-gateway-system -o jsonpath='{.status.addresses[0].value}')

# Create weighted record set
# Weight 90 for Ingress, Weight 10 for Gateway initially
aws route53 change-resource-record-sets --hosted-zone-id ZONE_ID --change-batch '{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "argocd.example.com",
        "Type": "A",
        "SetIdentifier": "ingress",
        "Weight": 90,
        "AliasTarget": {
          "HostedZoneId": "LB_ZONE_ID",
          "DNSName": "'$INGRESS_LB'",
          "EvaluateTargetHealth": true
        }
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "argocd.example.com",
        "Type": "A",
        "SetIdentifier": "gateway",
        "Weight": 10,
        "AliasTarget": {
          "HostedZoneId": "LB_ZONE_ID",
          "DNSName": "'$GATEWAY_LB'",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}'
```

#### Step 3: Gradual Traffic Shift

| Day | Ingress Weight | Gateway Weight | Notes |
|-----|----------------|----------------|-------|
| 1   | 90             | 10             | Initial deployment |
| 2   | 75             | 25             | If no issues |
| 3   | 50             | 50             | Equal split |
| 4   | 25             | 75             | Gateway preferred |
| 5   | 0              | 100            | Full cutover |

#### Step 4: Monitoring During Parallel Run

Monitor these metrics for both paths:

```bash
# Check HTTPRoute health
kubectl get httproute argocd-server -n argocd -o jsonpath='{.status.parents[0].conditions}' | jq .

# Monitor ArgoCD logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=100

# Check Envoy Gateway metrics (if Prometheus is configured)
# - envoy_cluster_upstream_rq_total
# - envoy_cluster_upstream_rq_5xx
# - envoy_cluster_upstream_rq_time
```

---

## DNS Cutover Process

### Pre-Cutover Checklist

- [ ] HTTPRoute is deployed and accepting traffic
- [ ] All validation tests pass (see [Validation Steps](#validation-steps))
- [ ] Monitoring is in place for both paths
- [ ] Rollback procedure is documented and tested
- [ ] Communication sent to stakeholders

### Cutover Steps

#### Step 1: Lower DNS TTL (24-48 hours before)

```bash
# Reduce TTL to 60 seconds for faster failover
aws route53 change-resource-record-sets --hosted-zone-id ZONE_ID --change-batch '{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "argocd.example.com",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "'$CURRENT_IP'"}]
    }
  }]
}'
```

#### Step 2: Update DNS Record

```bash
# Get Gateway external IP/hostname
GATEWAY_ENDPOINT=$(kubectl get gateway main-gateway -n envoy-gateway-system \
  -o jsonpath='{.status.addresses[0].value}')

# Update DNS to point to Gateway
aws route53 change-resource-record-sets --hosted-zone-id ZONE_ID --change-batch '{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "argocd.example.com",
      "Type": "A",
      "TTL": 60,
      "AliasTarget": {
        "HostedZoneId": "GATEWAY_LB_ZONE_ID",
        "DNSName": "'$GATEWAY_ENDPOINT'",
        "EvaluateTargetHealth": true
      }
    }
  }]
}'
```

#### Step 3: Validate Cutover

```bash
# Verify DNS propagation
dig argocd.example.com +short

# Test HTTPS connectivity
curl -I https://argocd.example.com/healthz

# Test ArgoCD CLI
argocd login argocd.example.com --grpc-web

# Verify in browser
echo "Open https://argocd.example.com in browser and verify login"
```

#### Step 4: Restore Normal TTL

After 24-48 hours of stable operation:

```bash
# Increase TTL back to normal (e.g., 300 seconds)
aws route53 change-resource-record-sets --hosted-zone-id ZONE_ID --change-batch '{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "argocd.example.com",
      "Type": "A",
      "TTL": 300,
      "AliasTarget": {
        "HostedZoneId": "GATEWAY_LB_ZONE_ID",
        "DNSName": "'$GATEWAY_ENDPOINT'",
        "EvaluateTargetHealth": true
      }
    }
  }]
}'
```

---

## Rollback Procedures

### Immediate Rollback (DNS)

If issues are detected, rollback DNS immediately:

```bash
#!/bin/bash
# rollback-dns.sh

HOSTED_ZONE_ID="YOUR_ZONE_ID"
INGRESS_ENDPOINT="YOUR_INGRESS_LB"
INGRESS_LB_ZONE_ID="YOUR_LB_ZONE_ID"

aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "argocd.example.com",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "'$INGRESS_LB_ZONE_ID'",
          "DNSName": "'$INGRESS_ENDPOINT'",
          "EvaluateTargetHealth": true
        }
      }
    }]
  }'

echo "Rollback initiated. DNS will update within TTL period."
echo "Current TTL: $(dig argocd.example.com +short | head -1)"
```

### HTTPRoute Rollback

Remove the HTTPRoute to ensure no traffic goes to Gateway:

```bash
# Delete HTTPRoute
kubectl delete httproute argocd-server -n argocd

# Verify Ingress is still working
kubectl get ingress argocd-server -n argocd
curl -I https://argocd.example.com/healthz
```

### Full Rollback Script

```bash
#!/bin/bash
# full-rollback.sh

set -e

echo "=== Starting ArgoCD Gateway Migration Rollback ==="

# Step 1: Rollback DNS
echo "Step 1: Rolling back DNS..."
./rollback-dns.sh

# Step 2: Delete HTTPRoute
echo "Step 2: Deleting HTTPRoute..."
kubectl delete httproute argocd-server -n argocd --ignore-not-found
kubectl delete httproute argocd-grpc -n argocd --ignore-not-found

# Step 3: Verify Ingress
echo "Step 3: Verifying Ingress..."
kubectl get ingress argocd-server -n argocd

# Step 4: Wait for DNS propagation
echo "Step 4: Waiting for DNS propagation (60 seconds)..."
sleep 60

# Step 5: Validate
echo "Step 5: Validating..."
curl -I https://argocd.example.com/healthz

echo "=== Rollback Complete ==="
```

### Rollback Decision Criteria

Initiate rollback if any of these occur:

| Issue | Severity | Action |
|-------|----------|--------|
| ArgoCD UI inaccessible | Critical | Immediate DNS rollback |
| gRPC/CLI not working | High | Investigate, rollback if >5 min |
| TLS errors | High | Check certs, rollback if invalid |
| 5xx errors >1% | Medium | Investigate, consider rollback |
| Latency increase >200% | Medium | Monitor, rollback if persists |

---

## Validation Steps

### Pre-Migration Validation

```bash
#!/bin/bash
# validate-pre-migration.sh

echo "=== Pre-Migration Validation ==="

# Check Gateway is ready
echo "1. Checking Gateway..."
kubectl get gateway main-gateway -n envoy-gateway-system -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}'

# Check GatewayClass
echo "2. Checking GatewayClass..."
kubectl get gatewayclass envoy-gateway

# Check TLS secret exists
echo "3. Checking TLS secret..."
kubectl get secret argocd-tls -n envoy-gateway-system

# Check ArgoCD is healthy
echo "4. Checking ArgoCD health..."
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server

echo "=== Pre-Migration Validation Complete ==="
```

### Post-Migration Validation

```bash
#!/bin/bash
# validate-post-migration.sh

echo "=== Post-Migration Validation ==="

# Check HTTPRoute status
echo "1. Checking HTTPRoute status..."
kubectl get httproute argocd-server -n argocd -o jsonpath='{.status.parents[0].conditions}' | jq .

# Test HTTPS
echo "2. Testing HTTPS..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://argocd.example.com/healthz)
if [ "$HTTP_STATUS" == "200" ]; then
    echo "   HTTPS: OK"
else
    echo "   HTTPS: FAILED (Status: $HTTP_STATUS)"
    exit 1
fi

# Test gRPC
echo "3. Testing gRPC (ArgoCD CLI)..."
argocd version --client
argocd login argocd.example.com --grpc-web --username admin --password "$ARGOCD_PASSWORD" --insecure || echo "   gRPC: Check manually"

# Test API
echo "4. Testing API..."
curl -s https://argocd.example.com/api/version | jq .

# Check for errors in logs
echo "5. Checking for errors in ArgoCD logs..."
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=50 | grep -i error || echo "   No errors found"

echo "=== Post-Migration Validation Complete ==="
```

### Continuous Validation (Monitoring)

Set up these alerts:

```yaml
# prometheus-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: argocd-gateway-alerts
spec:
  groups:
    - name: argocd-gateway
      rules:
        - alert: ArgoCDGatewayHighErrorRate
          expr: |
            sum(rate(envoy_cluster_upstream_rq_5xx{cluster_name="argocd_argocd-server_80"}[5m]))
            /
            sum(rate(envoy_cluster_upstream_rq_total{cluster_name="argocd_argocd-server_80"}[5m]))
            > 0.01
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "ArgoCD Gateway error rate > 1%"

        - alert: ArgoCDGatewayHighLatency
          expr: |
            histogram_quantile(0.99,
              sum(rate(envoy_cluster_upstream_rq_time_bucket{cluster_name="argocd_argocd-server_80"}[5m])) by (le)
            ) > 5000
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "ArgoCD Gateway p99 latency > 5s"
```

---

## Troubleshooting

### HTTPRoute Not Being Accepted

**Symptom:** HTTPRoute status shows `Accepted: False`

**Solution:**
```bash
# Check Gateway listeners
kubectl get gateway main-gateway -n envoy-gateway-system -o yaml

# Verify namespace is allowed
kubectl get gateway main-gateway -n envoy-gateway-system \
  -o jsonpath='{.spec.listeners[*].allowedRoutes}'

# Check for conflicting routes
kubectl get httproute -A
```

### TLS Errors

**Symptom:** Browser shows certificate errors

**Solution:**
```bash
# Verify secret exists and is valid
kubectl get secret argocd-tls -n envoy-gateway-system -o yaml

# Check certificate details
kubectl get secret argocd-tls -n envoy-gateway-system \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout

# Verify Gateway references the secret
kubectl get gateway main-gateway -n envoy-gateway-system \
  -o jsonpath='{.spec.listeners[?(@.name=="https")].tls}'
```

### gRPC Not Working

**Symptom:** ArgoCD CLI fails to connect

**Solution:**
```bash
# Test with grpc-web
argocd login argocd.example.com --grpc-web

# Check if HTTP/2 is enabled on Gateway
kubectl get gateway main-gateway -n envoy-gateway-system -o yaml

# Verify ArgoCD server supports grpc-web
kubectl get configmap argocd-cmd-params-cm -n argocd -o yaml
```

### 502/503 Errors

**Symptom:** Intermittent 502 or 503 errors

**Solution:**
```bash
# Check ArgoCD pods are healthy
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server

# Check service endpoints
kubectl get endpoints argocd-server -n argocd

# Check Envoy Gateway logs
kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=main-gateway
```

---

## Multi-Cluster Rollout Strategy

For 60+ clusters, use a phased rollout:

### Phase 1: Pilot (2-3 clusters)
- Select non-critical clusters
- Complete full migration cycle
- Document issues and solutions

### Phase 2: Early Adopters (10% of clusters)
- Apply lessons from pilot
- Validate automation scripts
- Establish success metrics

### Phase 3: Majority (70% of clusters)
- Use automated rollout
- Batch clusters by region/environment
- Monitor aggregate metrics

### Phase 4: Laggards (remaining clusters)
- Handle special cases
- Address any remaining issues
- Complete documentation

### Rollout Automation

```bash
#!/bin/bash
# batch-rollout.sh

CLUSTERS_FILE="clusters.txt"
BATCH_SIZE=5
WAIT_BETWEEN_BATCHES=3600  # 1 hour

while IFS= read -r cluster; do
    echo "Migrating cluster: $cluster"

    # Switch context
    kubectl config use-context "$cluster"

    # Apply HTTPRoute
    kubectl apply -f argocd-httproute.yaml

    # Validate
    ./validate-post-migration.sh

    # Increment counter
    ((count++))

    # Pause between batches
    if [ $((count % BATCH_SIZE)) -eq 0 ]; then
        echo "Batch complete. Waiting $WAIT_BETWEEN_BATCHES seconds..."
        sleep $WAIT_BETWEEN_BATCHES
    fi
done < "$CLUSTERS_FILE"
```

---

## References

- [Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
- [Envoy Gateway Documentation](https://gateway.envoyproxy.io/)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Migration Examples](./MIGRATION-EXAMPLES.md)
