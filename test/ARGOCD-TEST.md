# ArgoCD Parallel Testing with Envoy Gateway

Test Envoy Gateway alongside your existing Ingress without disruption.

## Architecture

```text
                    ┌─────────────────────┐
                    │   Existing Ingress  │ ← argocd.yourdomain.com (keep working)
                    │   (nginx/traefik)   │
                    └──────────┬──────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────┐
│                      ArgoCD Server                           │
│                      (argocd namespace)                      │
└──────────────────────────────────────────────────────────────┘
                               ▲
                               │
                    ┌──────────┴──────────┐
                    │   Envoy Gateway     │ ← NEW: test via Gateway IP
                    │   (argocd-gw)       │
                    └─────────────────────┘
```

## Prerequisites

1. Envoy Gateway installed (controller running)
2. GatewayClass `eg` exists
3. ArgoCD running with TLS secret `argocd-server-tls`

## Step 1: Ensure ArgoCD accepts plaintext (for TLS termination at gateway)

```bash
# Check if already set
kubectl get cm argocd-cmd-params-cm -n argocd -o jsonpath='{.data.server\.insecure}'

# If not set, enable it (ArgoCD will accept HTTP from gateway)
kubectl patch cm argocd-cmd-params-cm -n argocd \
  --type merge -p '{"data":{"server.insecure":"true"}}'

# Restart ArgoCD server to pick up change
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd
```

## Step 2: Deploy Envoy Gateway for ArgoCD

```bash
kubectl apply -f 05-argocd-envoy.yaml
```

## Step 3: Wait for Gateway to get an IP

```bash
# Watch until ADDRESS is assigned
kubectl get gateway argocd-gw -n argocd -w

# Or wait with timeout
kubectl wait --for=jsonpath='{.status.addresses[0].value}' gateway/argocd-gw -n argocd --timeout=120s
```

## Step 4: Get the Gateway IP

```bash
export GW_IP=$(kubectl get gateway argocd-gw -n argocd -o jsonpath='{.status.addresses[0].value}')
echo "Gateway IP: $GW_IP"
```

## Step 5: Test via Gateway IP

### Test HTTPS (with IP, skip cert verification)
```bash
curl -k https://$GW_IP/
```

### Test with Host header (simulates DNS)
```bash
curl -k -H "Host: argocd.yourdomain.com" https://$GW_IP/
```

### Test ArgoCD CLI via Gateway
```bash
# Login using IP (skip TLS verify for testing)
argocd login $GW_IP --insecure --grpc-web

# Or with username/password
argocd login $GW_IP --insecure --grpc-web --username admin --password $(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d)

# Test - list apps
argocd app list
```

## Step 6: Verify both work

```bash
# Existing Ingress (should still work)
curl -k https://argocd.yourdomain.com/

# New Envoy Gateway
curl -k https://$GW_IP/
```

## Step 7: Ready to switch? Update DNS

Once testing confirms Envoy Gateway works:

1. Update DNS to point `argocd.yourdomain.com` to `$GW_IP`
2. Wait for DNS propagation
3. Test again with hostname
4. Delete old Ingress when confident

```bash
# After DNS switch, test with real hostname
curl -k https://argocd.yourdomain.com/
argocd login argocd.yourdomain.com --insecure --grpc-web
```

## Rollback

If something goes wrong, simply:

```bash
# Delete the Gateway (Ingress keeps working)
kubectl delete -f 05-argocd-envoy.yaml

# Revert DNS if changed
```

## Cleanup (after successful migration)

```bash
# Delete old Ingress
kubectl delete ingress argocd-server -n argocd

# Optional: Remove insecure flag if using mTLS
# kubectl patch cm argocd-cmd-params-cm -n argocd \
#   --type merge -p '{"data":{"server.insecure":"false"}}'
```

## Troubleshooting

### Gateway has no IP
```bash
kubectl describe gateway argocd-gw -n argocd
kubectl get svc -n envoy-gateway-system
```

### Connection refused
```bash
# Check Envoy pods
kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=argocd

# Check logs
kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-namespace=argocd
```

### TLS errors
```bash
# Verify secret exists
kubectl get secret argocd-server-tls -n argocd

# Check certificate
kubectl get secret argocd-server-tls -n argocd -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | head -20
```

### gRPC not working
```bash
# Test gRPC connectivity
grpcurl -insecure $GW_IP:443 list

# Check GRPCRoute status
kubectl get grpcroute -n argocd -o yaml
```
