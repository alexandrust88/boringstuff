# Envoy Gateway Test Setup

Simple test manifests for Envoy Gateway.

## Prerequisites

Install Envoy Gateway via ArgoCD:
```bash
# https://gateway.envoyproxy.io/v1.5/install/install-argocd/
kubectl apply -f https://raw.githubusercontent.com/envoyproxy/gateway/v1.5.0/examples/argocd/application.yaml
```

Wait for it to be ready:
```bash
kubectl wait --for=condition=Available deployment/envoy-gateway -n envoy-gateway-system --timeout=300s
```

## Deploy Test Setup

```bash
# Apply in order
kubectl apply -f 01-gateway-class.yaml
kubectl apply -f 02-gateway.yaml
kubectl apply -f 03-sample-app.yaml
kubectl apply -f 04-httproute.yaml
```

Or all at once:
```bash
kubectl apply -f .
```

## Verify

```bash
# Check GatewayClass
kubectl get gatewayclass eg

# Check Gateway (wait for Address)
kubectl get gateway eg -n envoy-gateway-system

# Check HTTPRoute
kubectl get httproute -n demo

# Check sample app
kubectl get pods -n demo
```

## Test

```bash
# Get Gateway IP
export GATEWAY_IP=$(kubectl get gateway eg -n envoy-gateway-system -o jsonpath='{.status.addresses[0].value}')

# Test HTTP
curl -v http://$GATEWAY_IP/

# Should return echo response with pod info
```

## Cleanup

```bash
kubectl delete -f .
```
