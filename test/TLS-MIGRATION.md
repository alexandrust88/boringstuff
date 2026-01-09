# TLS Certificate Migration for Envoy Gateway

Your current setup: Ingress with cert-manager annotation creates TLS secret in `argocd` namespace.

## Current Ingress (example)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - argocd.yourdomain.com
      secretName: argocd-server-tls  # cert-manager creates this
  rules:
    - host: argocd.yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
```

cert-manager creates: `argocd-server-tls` secret in `argocd` namespace.

---

## Option 1: Gateway in same namespace (Recommended for testing)

Since your Gateway is in `argocd` namespace, it can directly use the existing secret.

```yaml
# 05-argocd-envoy.yaml already does this:
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: argocd-gw
  namespace: argocd  # Same namespace as secret
spec:
  gatewayClassName: eg
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: argocd-server-tls  # Uses existing secret directly
```

**No changes needed** - the Gateway can use the same secret cert-manager created for the Ingress.

---

## Option 2: Create Certificate for Gateway directly

If you want cert-manager to manage the cert for Gateway (independent of Ingress):

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-gw-tls
  namespace: argocd
spec:
  secretName: argocd-gw-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - argocd.yourdomain.com
```

Then reference `argocd-gw-tls` in the Gateway.

---

## Option 3: Copy secret to another namespace

If Gateway needs to be in a different namespace (e.g., `envoy-gateway-system`):

### Manual copy (one-time)
```bash
kubectl get secret argocd-server-tls -n argocd -o yaml | \
  sed 's/namespace: argocd/namespace: envoy-gateway-system/' | \
  kubectl apply -f -
```

### Using reflector (automatic sync)
Install [reflector](https://github.com/emberstack/kubernetes-reflector):
```bash
helm repo add emberstack https://emberstack.github.io/helm-charts
helm install reflector emberstack/reflector -n kube-system
```

Annotate source secret:
```bash
kubectl annotate secret argocd-server-tls -n argocd \
  reflector.v1.k8s.emberstack.com/reflection-allowed="true" \
  reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces="envoy-gateway-system"
```

Create reflected secret:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-server-tls
  namespace: envoy-gateway-system
  annotations:
    reflector.v1.k8s.emberstack.com/reflects: "argocd/argocd-server-tls"
type: kubernetes.io/tls
data: {}  # Will be populated by reflector
```

---

## Option 4: ReferenceGrant (Gateway API native)

Allow Gateway in one namespace to reference Secret in another:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-tls
  namespace: argocd  # Where the secret is
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: Gateway
      namespace: envoy-gateway-system  # Where Gateway is
  to:
    - group: ""
      kind: Secret
      name: argocd-server-tls
```

Then Gateway can reference cross-namespace:
```yaml
tls:
  certificateRefs:
    - kind: Secret
      name: argocd-server-tls
      namespace: argocd  # Cross-namespace reference
```

---

## Verify Certificate

```bash
# Check secret exists
kubectl get secret argocd-server-tls -n argocd

# Check certificate details
kubectl get secret argocd-server-tls -n argocd -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -text -noout | head -20

# Check expiry
kubectl get secret argocd-server-tls -n argocd -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -enddate -noout
```

## Test TLS with Gateway

```bash
export GW_IP=$(kubectl get gateway argocd-gw -n argocd -o jsonpath='{.status.addresses[0].value}')

# Test with SNI (important for TLS)
curl -v --resolve argocd.yourdomain.com:443:$GW_IP https://argocd.yourdomain.com/

# Check certificate served
echo | openssl s_client -connect $GW_IP:443 -servername argocd.yourdomain.com 2>/dev/null | \
  openssl x509 -text -noout | head -20
```
