# envoy gateway - security

tls management, cert-manager integration, security policies, rbac, pod security, and hardening.

---

## tls certificate management

### option 1: cert-manager integration (recommended)

#### clusterissuer setup

```yaml
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
              - name: main-gateway
                namespace: envoy-gateway-system
                kind: Gateway
```

#### certificate resource

```yaml
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
  duration: 2160h              # 90 days
  renewBefore: 720h            # 30 days before expiry
  privateKey:
    algorithm: ECDSA
    size: 256
```

### option 2: existing certificate (wildcard)

```bash
kubectl create secret tls wildcard-platform-tls \
  -n envoy-gateway-system \
  --cert=./fullchain.pem \
  --key=./privkey.pem
```

### option 3: reuse ingress cert-manager secret

if gateway is in the same namespace as the existing secret, it can use it directly:

```yaml
# gateway in argocd namespace can use argocd-server-tls directly
listeners:
  - name: https
    tls:
      certificateRefs:
        - kind: Secret
          name: argocd-server-tls    # created by cert-manager for ingress
```

### cross-namespace tls with referencegrant

when gateway and secret are in different namespaces:

```yaml
# in the secret's namespace
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-tls
  namespace: argocd                    # where secret lives
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: Gateway
      namespace: envoy-gateway-system  # where gateway lives
  to:
    - group: ""
      kind: Secret
      name: argocd-server-tls
```

### cross-namespace tls with reflector

auto-sync secrets across namespaces:

```bash
# install reflector
helm install reflector emberstack/reflector -n kube-system

# annotate source secret
kubectl annotate secret argocd-server-tls -n argocd \
  reflector.v1.k8s.emberstack.com/reflection-allowed="true" \
  reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces="envoy-gateway-system"
```

### certificate verification commands

```bash
# check secret exists and has data
kubectl get secret <tls-secret> -n <ns> -o yaml | grep -E 'tls.crt|tls.key'

# verify certificate content
kubectl get secret <tls-secret> -n <ns> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | head -20

# check expiry
kubectl get secret <tls-secret> -n <ns> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -enddate -noout

# test tls with gateway
GW_IP=$(kubectl get gateway <name> -n <ns> -o jsonpath='{.status.addresses[0].value}')
curl -v --resolve <hostname>:443:$GW_IP https://<hostname>/

# check certificate served by gateway
echo | openssl s_client -connect $GW_IP:443 -servername <hostname> 2>/dev/null | openssl x509 -text -noout | head -20
```

### manual certificate rotation

```bash
# 1. create new secret
kubectl create secret tls app-tls-new -n <ns> --cert=./new-cert.pem --key=./new-key.pem

# 2. update gateway to use new secret
kubectl patch gateway <name> -n <ns> --type='json' \
  -p='[{"op": "replace", "path": "/spec/listeners/1/tls/certificateRefs/0/name", "value": "app-tls-new"}]'

# 3. verify
openssl s_client -connect <hostname>:443 -servername <hostname> < /dev/null 2>/dev/null | openssl x509 -dates -noout

# 4. clean up old secret
kubectl delete secret app-tls -n <ns>
```

---

## tls configuration

### clienttrafficpolicy tls settings

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: ClientTrafficPolicy
metadata:
  name: tls-hardening
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: main-gateway
  tls:
    minVersion: TLSv1_2
    ciphers:
      - ECDHE-ECDSA-AES128-GCM-SHA256
      - ECDHE-RSA-AES128-GCM-SHA256
      - ECDHE-ECDSA-AES256-GCM-SHA384
      - ECDHE-RSA-AES256-GCM-SHA384
```

recommended: tls 1.2 minimum (not 1.3 only - some clients still need 1.2)

---

## security policies

### cors

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: cors-policy
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: app-route
  cors:
    allowOrigins:
      - "https://app.example.com"
      - "https://*.example.com"
    allowMethods: [GET, POST, PUT, DELETE, OPTIONS]
    allowHeaders: [Authorization, Content-Type, X-Requested-With]
    allowCredentials: true
    maxAge: 86400s
```

### rate limiting (local per-pod)

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: rate-limit
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: app-route
  rateLimit:
    type: Local
    local:
      rules:
        # global limit
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
```

### ip allowlisting / denylisting

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: ip-allowlist
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: app-route
  authorization:
    defaultAction: Deny
    rules:
      - name: internal-networks
        action: Allow
        principal:
          clientCIDRs:
            - "10.0.0.0/8"
            - "172.16.0.0/12"
            - "192.168.0.0/16"
      - name: partner-access
        action: Allow
        principal:
          clientCIDRs:
            - "203.0.113.0/24"
```

advantage over load balancer ip restrictions: per-route granularity, dynamic updates, audit logging.

### jwt authentication

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: jwt-auth
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: app-route
  jwt:
    providers:
      - name: keycloak
        issuer: https://keycloak.example.com/realms/platform
        remoteJWKS:
          uri: https://keycloak.example.com/realms/platform/protocol/openid-connect/certs
        claimToHeaders:
          - claim: sub
            header: x-user-id
          - claim: email
            header: x-user-email
```

---

## rbac model

### platform team: full gateway control

```yaml
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
```

### app teams: route management only

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: route-admin
  namespace: team-a-ns
rules:
  - apiGroups: ["gateway.networking.k8s.io"]
    resources: ["httproutes", "grpcroutes"]
    verbs: ["*"]
  - apiGroups: ["gateway.envoyproxy.io"]
    resources: ["backendtrafficpolicies"]
    verbs: ["*"]
```

### multi-tenancy isolation

```
envoy-gateway-system/ (platform team owns)
  GatewayClass: eg
  Gateway: shared-gateway
  EnvoyProxy: production-config

team-a-ns/ (team a owns their routes)
  HTTPRoute: app-a (parentRef -> shared-gateway)
  BackendTrafficPolicy: app-a-policy

team-b-ns/ (team b owns their routes)
  HTTPRoute: app-b (parentRef -> shared-gateway)
  BackendTrafficPolicy: app-b-policy
```

teams can only create routes in their own namespace. gateway allowedRoutes controls which namespaces can attach.

---

## pod security hardening

### envoyproxy security context

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: hardened-proxy
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        pod:
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            runAsGroup: 65532
            fsGroup: 65532
            seccompProfile:
              type: RuntimeDefault
        container:
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

### namespace pod security standards

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: envoy-gateway-system
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

### network policies

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: envoy-proxy-policy
  namespace: envoy-gateway-system
spec:
  podSelector:
    matchLabels:
      gateway.envoyproxy.io/owning-gateway-name: main-gateway
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # allow external traffic (from lb)
    - ports:
        - port: 8080
        - port: 8443
    # allow prometheus scraping
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - port: 19001
  egress:
    # allow to backend services
    - to:
        - namespaceSelector: {}
      ports:
        - port: 80
        - port: 443
        - port: 8080
    # allow to controller (xds)
    - to:
        - podSelector:
            matchLabels:
              control-plane: envoy-gateway
      ports:
        - port: 18000
    # allow dns
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
```

---

## security headers

add via httproute response header modification:

```yaml
filters:
  - type: ResponseHeaderModifier
    responseHeaderModifier:
      set:
        - name: X-Frame-Options
          value: DENY
        - name: X-Content-Type-Options
          value: nosniff
        - name: X-XSS-Protection
          value: "1; mode=block"
        - name: Strict-Transport-Security
          value: "max-age=31536000; includeSubDomains"
        - name: Content-Security-Policy
          value: "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
        - name: Referrer-Policy
          value: strict-origin-when-cross-origin
```

---

## azure-specific security

### nsg rules (terraform)

```hcl
# allow http
resource "azurerm_network_security_rule" "envoy_http" {
  name                       = "allow-envoy-http"
  priority                   = 100
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "80"
  source_address_prefix      = "Internet"
  destination_address_prefix = "*"
  resource_group_name         = azurerm_resource_group.aks.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

# allow https
resource "azurerm_network_security_rule" "envoy_https" {
  name                       = "allow-envoy-https"
  priority                   = 110
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "443"
  source_address_prefix      = "Internet"
  destination_address_prefix = "*"
  resource_group_name         = azurerm_resource_group.aks.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

# required: azure lb health probes
resource "azurerm_network_security_rule" "azure_lb_probe" {
  name                       = "allow-azure-lb-probe"
  priority                   = 120
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "*"
  source_address_prefix      = "AzureLoadBalancer"
  destination_address_prefix = "*"
  resource_group_name         = azurerm_resource_group.aks.name
  network_security_group_name = azurerm_network_security_group.aks.name
}
```

### azure lb ip allowlisting (simple)

```yaml
annotations:
  service.beta.kubernetes.io/azure-allowed-ip-ranges: "10.0.0.0/8,203.0.113.0/24"
```

limitation: applies to entire service, no per-route granularity.
prefer SecurityPolicy for fine-grained control.

### internal load balancer (private clusters)

```yaml
annotations:
  service.beta.kubernetes.io/azure-load-balancer-internal: "true"
  service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "snet-aks-ingress"
  service.beta.kubernetes.io/azure-load-balancer-ipv4: "10.100.1.10"
```

### static ip management

```hcl
# pre-provision public ip via terraform
resource "azurerm_public_ip" "envoy_gateway" {
  name                = "pip-envoy-gateway-${var.environment}-${var.region}"
  resource_group_name = azurerm_resource_group.networking.name
  location            = azurerm_resource_group.networking.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]

  lifecycle {
    prevent_destroy = true
  }
}

# aks managed identity needs Network Contributor on the public ip
resource "azurerm_role_assignment" "aks_pip_contributor" {
  scope                = azurerm_public_ip.envoy_gateway.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
}
```

reference in envoy gateway:
```yaml
annotations:
  service.beta.kubernetes.io/azure-load-balancer-resource-group: "rg-networking-prod"
  service.beta.kubernetes.io/azure-pip-name: "pip-envoy-gateway-prod-westeurope"
```

key: public ip in separate resource group survives cluster deletion.

---

## security checklist

- [ ] tls 1.2 minimum enforced via clienttrafficpolicy
- [ ] strong cipher suites only
- [ ] cert-manager for automatic certificate renewal
- [ ] certificate expiry alerts (< 14 days)
- [ ] pod security standards: restricted
- [ ] securitycontext: runAsNonRoot, readOnlyRootFilesystem, drop ALL capabilities
- [ ] network policies limiting ingress/egress
- [ ] rbac: platform team owns gateways, app teams own routes only
- [ ] rate limiting on auth endpoints
- [ ] security response headers (hsts, csp, x-frame-options)
- [ ] access logging enabled (json format)
- [ ] monitoring and alerting for error rates, latency
