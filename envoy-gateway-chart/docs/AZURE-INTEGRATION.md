# Azure Integration Guide

This document covers Azure-specific configuration for Envoy Gateway across our 60+ AKS cluster deployment, including LoadBalancer configuration, static IP management, DNS integration, and network security.

---

## Table of Contents

1. [LoadBalancer Configuration](#loadbalancer-configuration)
2. [Static IP Preservation Strategy](#static-ip-preservation-strategy)
3. [DNS Integration](#dns-integration)
4. [Health Probe Configuration](#health-probe-configuration)
5. [Network Security](#network-security)
6. [Private Clusters](#private-clusters)
7. [Multi-Region Considerations](#multi-region-considerations)
8. [Cost Optimization](#cost-optimization)
9. [Troubleshooting Azure Issues](#troubleshooting-azure-issues)

---

## LoadBalancer Configuration

### Azure Load Balancer Annotations

When Envoy Gateway creates a Service of type `LoadBalancer`, you can control Azure Load Balancer behavior through annotations.

#### Complete Annotation Reference

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: azure-proxy-config
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: LoadBalancer
        annotations:
          # Resource Group for Public IP (REQUIRED for static IP)
          service.beta.kubernetes.io/azure-load-balancer-resource-group: "rg-networking-prod"

          # Use existing Public IP by name
          service.beta.kubernetes.io/azure-pip-name: "pip-envoy-gateway-prod"

          # OR use existing Public IP by resource ID (for cross-subscription)
          # service.beta.kubernetes.io/azure-pip-prefix-id: "/subscriptions/xxx/resourceGroups/rg-networking/providers/Microsoft.Network/publicIPPrefixes/pip-prefix"

          # Internal Load Balancer (private IP only)
          # service.beta.kubernetes.io/azure-load-balancer-internal: "true"

          # Internal LB subnet (required if internal)
          # service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "snet-aks-internal"

          # Load Balancer SKU (Standard recommended)
          service.beta.kubernetes.io/azure-load-balancer-sku: "Standard"

          # Idle timeout (4-30 minutes, default 4)
          service.beta.kubernetes.io/azure-load-balancer-tcp-idle-timeout: "10"

          # Disable floating IP (direct server return)
          service.beta.kubernetes.io/azure-load-balancer-disable-tcp-reset: "false"

          # Health probe protocol override
          service.beta.kubernetes.io/azure-load-balancer-health-probe-protocol: "Tcp"

          # Health probe port (if different from service port)
          service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: "/healthz"

          # Allowed source IP ranges (alternative to NSG)
          # service.beta.kubernetes.io/azure-allowed-ip-ranges: "10.0.0.0/8,192.168.0.0/16"

          # Additional tags for Azure resources
          service.beta.kubernetes.io/azure-additional-public-ips: ""
```

### Standard vs Basic SKU

| Feature | Standard SKU | Basic SKU |
|---------|--------------|-----------|
| **Availability Zones** | Supported | Not supported |
| **Backend pool size** | Up to 1000 | Up to 300 |
| **Health probes** | HTTP, HTTPS, TCP | HTTP, TCP |
| **Static IP** | Supported | Dynamic only |
| **SLA** | 99.99% | No SLA |
| **Outbound rules** | Supported | Not supported |
| **Recommendation** | **Use this** | Not recommended |

**Important**: AKS 1.25+ defaults to Standard SKU. Always use Standard for production.

---

## Static IP Preservation Strategy

### Why Static IPs Matter

In our 60+ cluster environment, static IPs are critical for:
- DNS record stability (no TTL propagation delays)
- Firewall rule consistency (partner/customer allowlists)
- Disaster recovery (known IP to route to)
- Audit and compliance (traceable IPs)

### Pre-Provisioning Strategy

#### Step 1: Create Public IP via Terraform/ARM

```hcl
# terraform/modules/aks-networking/public-ip.tf

resource "azurerm_public_ip" "envoy_gateway" {
  name                = "pip-envoy-gateway-${var.environment}-${var.region}"
  resource_group_name = azurerm_resource_group.networking.name
  location            = azurerm_resource_group.networking.location
  allocation_method   = "Static"
  sku                 = "Standard"

  zones = ["1", "2", "3"]  # Zone-redundant

  tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Purpose     = "envoy-gateway"
    Cluster     = var.cluster_name
  }

  lifecycle {
    prevent_destroy = true  # Prevent accidental deletion
  }
}

# Output for Helm values
output "envoy_gateway_public_ip" {
  value = azurerm_public_ip.envoy_gateway.ip_address
}

output "envoy_gateway_pip_name" {
  value = azurerm_public_ip.envoy_gateway.name
}
```

#### Step 2: Configure Envoy Gateway to Use Static IP

```yaml
# values.yaml for envoy-gateway wrapper chart
envoyProxy:
  provider:
    kubernetes:
      envoyService:
        annotations:
          service.beta.kubernetes.io/azure-load-balancer-resource-group: "rg-networking-prod"
          service.beta.kubernetes.io/azure-pip-name: "pip-envoy-gateway-prod-westeurope"

# Or directly in EnvoyProxy resource
```

#### Step 3: Verify IP Assignment

```bash
# Check Service got the expected IP
kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=argocd-gateway

# Expected output:
# NAME                           TYPE           CLUSTER-IP     EXTERNAL-IP    PORT(S)
# envoy-argocd-gateway-xxx       LoadBalancer   10.0.xxx.xxx   20.x.x.x       80:3xxxx/TCP,443:3yyyy/TCP
```

### Handling IP During Cluster Recreation

```
Scenario: AKS cluster needs to be recreated (upgrade, disaster)

Timeline:
1. T-0: Current cluster running with pip-envoy-gateway-prod (20.x.x.x)
2. T-1: Create new cluster (different name)
3. T-2: Deploy Envoy Gateway with SAME pip-name annotation
4. T-3: Azure LB attaches to existing Public IP
5. T-4: Traffic flows to new cluster (no DNS change needed)
6. T-5: Delete old cluster

Key: Public IP is in separate resource group from AKS, survives cluster deletion
```

### Cross-Subscription Public IP

For centralized networking (hub-spoke model):

```yaml
annotations:
  # Reference IP in different subscription
  service.beta.kubernetes.io/azure-pip-prefix-id: >-
    /subscriptions/networking-subscription-id/resourceGroups/rg-hub-networking/providers/Microsoft.Network/publicIPPrefixes/pip-prefix-envoy
```

Required RBAC:
```hcl
# AKS managed identity needs Network Contributor on the Public IP
resource "azurerm_role_assignment" "aks_pip_contributor" {
  scope                = azurerm_public_ip.envoy_gateway.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
}
```

---

## DNS Integration

### Architecture

```
                    +---------------------------+
                    |    Azure DNS Zone         |
                    |  platform.example.com     |
                    +-------------+-------------+
                                  |
                    +-------------+-------------+
                    |                           |
                    v                           v
            +---------------+          +----------------+
            | A Record      |          | A Record       |
            | argocd.xxx    |          | *.apps.xxx     |
            | -> 20.x.x.x   |          | -> 20.x.x.x    |
            +---------------+          +----------------+
```

### Option 1: External-DNS (Recommended)

External-DNS automatically manages DNS records based on Gateway/HTTPRoute resources.

```yaml
# external-dns values.yaml
provider: azure
azure:
  resourceGroup: rg-dns-prod
  subscriptionId: xxx-xxx-xxx
  tenantId: xxx-xxx-xxx
  useManagedIdentityExtension: true

sources:
  - gateway-httproute    # Watch HTTPRoute resources
  - gateway-grpcroute    # Watch GRPCRoute resources

domainFilters:
  - platform.example.com

policy: sync  # Create and delete records

txtOwnerId: envoy-gateway-cluster-01

# Filter by annotation (optional)
annotationFilter: "external-dns.alpha.kubernetes.io/enabled=true"
```

**HTTPRoute with DNS annotation:**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    external-dns.alpha.kubernetes.io/enabled: "true"
    external-dns.alpha.kubernetes.io/hostname: "argocd.platform.example.com"
    external-dns.alpha.kubernetes.io/ttl: "300"
spec:
  parentRefs:
    - name: argocd-gateway
  hostnames:
    - "argocd.platform.example.com"
  # ...
```

### Option 2: Terraform-Managed DNS

For environments where DNS changes require change control:

```hcl
# terraform/modules/dns/records.tf

resource "azurerm_dns_a_record" "argocd" {
  name                = "argocd"
  zone_name           = azurerm_dns_zone.platform.name
  resource_group_name = azurerm_resource_group.dns.name
  ttl                 = 300
  records             = [data.azurerm_public_ip.envoy_gateway.ip_address]

  tags = {
    ManagedBy = "terraform"
    Service   = "argocd"
  }
}

resource "azurerm_dns_a_record" "apps_wildcard" {
  name                = "*.apps"
  zone_name           = azurerm_dns_zone.platform.name
  resource_group_name = azurerm_resource_group.dns.name
  ttl                 = 300
  records             = [data.azurerm_public_ip.envoy_gateway.ip_address]

  tags = {
    ManagedBy = "terraform"
    Service   = "envoy-gateway-wildcard"
  }
}
```

### DNS TTL Recommendations

| Record Type | TTL | Rationale |
|-------------|-----|-----------|
| Production (static IP) | 300-3600s | Low enough for DR, high enough for cache efficiency |
| Staging | 60-300s | Faster propagation for testing |
| During migration | 60s | Quick failover capability |
| After stable | 3600s | Reduce DNS query load |

---

## Health Probe Configuration

### Azure Load Balancer Health Probes

Azure LB health probes determine which backend nodes receive traffic.

#### Default Behavior

By default, AKS configures health probes based on the Service port. For Envoy Gateway:

```
Health Probe: TCP to NodePort (e.g., 32443)
Interval: 5 seconds
Unhealthy threshold: 2 failures
```

#### Custom Health Probe Configuration

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: azure-proxy-config
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: LoadBalancer
        annotations:
          # Use HTTP health probe instead of TCP
          service.beta.kubernetes.io/azure-load-balancer-health-probe-protocol: "Http"
          service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: "/healthz"
          service.beta.kubernetes.io/azure-load-balancer-health-probe-interval: "5"
          service.beta.kubernetes.io/azure-load-balancer-health-probe-num-of-probe: "2"
```

### Envoy Proxy Health Endpoints

Envoy exposes health endpoints on the admin port (default 19001):

| Endpoint | Purpose | Response |
|----------|---------|----------|
| `/ready` | Readiness probe | 200 if ready |
| `/healthz` | General health | 200 if healthy |
| `/server_info` | Server information | JSON with version, state |

#### Kubernetes Probe Configuration

```yaml
# In EnvoyProxy spec
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyDeployment:
        container:
          livenessProbe:
            httpGet:
              path: /healthz
              port: 19001
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 3

          readinessProbe:
            httpGet:
              path: /ready
              port: 19001
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 2
```

### Health Check Flow

```
Azure LB Health Probe (TCP/32443 or HTTP/32443/healthz)
                    |
                    v
         AKS Node (NodePort)
                    |
                    v
         Envoy Pod (8443 or 19001)
                    |
                    +---> If healthy: Node stays in LB backend pool
                    |
                    +---> If unhealthy: Node removed from pool (no traffic)
```

---

## Network Security

### Network Security Groups (NSG)

#### Required Inbound Rules

```hcl
# terraform/modules/aks-networking/nsg.tf

resource "azurerm_network_security_rule" "envoy_http" {
  name                        = "allow-envoy-http"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "Internet"  # Or specific CIDRs
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.aks.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

resource "azurerm_network_security_rule" "envoy_https" {
  name                        = "allow-envoy-https"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "Internet"  # Or specific CIDRs
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.aks.name
  network_security_group_name = azurerm_network_security_group.aks.name
}

# Azure Load Balancer health probes (REQUIRED)
resource "azurerm_network_security_rule" "azure_lb_probe" {
  name                        = "allow-azure-lb-probe"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.aks.name
  network_security_group_name = azurerm_network_security_group.aks.name
}
```

### IP Allowlisting Options

#### Option 1: Azure LB Annotation (Simple)

```yaml
annotations:
  service.beta.kubernetes.io/azure-allowed-ip-ranges: "10.0.0.0/8,203.0.113.0/24"
```

**Limitation**: Applies to entire Service, cannot differentiate by path.

#### Option 2: Envoy SecurityPolicy (Recommended)

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: ip-allowlist
  namespace: argocd
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: argocd-server

  authorization:
    defaultAction: Deny
    rules:
      # Allow internal networks
      - name: internal
        action: Allow
        principal:
          clientCIDRs:
            - "10.0.0.0/8"
            - "172.16.0.0/12"
            - "192.168.0.0/16"

      # Allow specific partner IPs
      - name: partner-access
        action: Allow
        principal:
          clientCIDRs:
            - "203.0.113.0/24"  # Partner A
            - "198.51.100.0/24" # Partner B
```

**Advantage**: Per-route granularity, dynamic updates, audit logging.

### Azure Firewall Integration

For environments with Azure Firewall (hub-spoke):

```
Internet
    |
    v
Azure Firewall (Hub VNET)
    |
    | DNAT Rule: 20.x.x.x:443 -> 10.y.y.y:443 (AKS LB Internal IP)
    |
    v
Internal Load Balancer (AKS Spoke VNET)
    |
    v
Envoy Gateway Pods
```

#### Internal Load Balancer Configuration

```yaml
annotations:
  service.beta.kubernetes.io/azure-load-balancer-internal: "true"
  service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "snet-aks-ingress"
```

---

## Private Clusters

### Architecture for Private AKS

```
+------------------------------------------------------------------+
|                         Hub VNET                                 |
|  +------------------------------------------------------------+  |
|  |                    Azure Firewall                          |  |
|  |                    (Public IP: 20.x.x.x)                   |  |
|  +-----------------------------+------------------------------+  |
|                                |                                 |
|                                | VNET Peering                    |
+------------------------------------------------------------------+
                                 |
+------------------------------------------------------------------+
|                        Spoke VNET (AKS)                          |
|  +------------------------------------------------------------+  |
|  |                    AKS Private Cluster                     |  |
|  |                                                            |  |
|  |  +------------------+  +------------------+                |  |
|  |  | Internal LB      |  | Envoy Pods       |                |  |
|  |  | (10.y.y.y)       |  |                  |                |  |
|  |  +------------------+  +------------------+                |  |
|  +------------------------------------------------------------+  |
+------------------------------------------------------------------+
```

### Configuration for Private Cluster

```yaml
# EnvoyProxy for internal-only access
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: internal-proxy
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: LoadBalancer
        annotations:
          service.beta.kubernetes.io/azure-load-balancer-internal: "true"
          service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "snet-aks-ingress"

          # Use static internal IP
          service.beta.kubernetes.io/azure-load-balancer-ipv4: "10.100.1.10"
```

### Azure Firewall DNAT Rules

```hcl
resource "azurerm_firewall_nat_rule_collection" "envoy_gateway" {
  name                = "envoy-gateway-dnat"
  azure_firewall_name = azurerm_firewall.hub.name
  resource_group_name = azurerm_resource_group.hub.name
  priority            = 100
  action              = "Dnat"

  rule {
    name                  = "https-to-aks"
    source_addresses      = ["*"]  # Or specific source IPs
    destination_ports     = ["443"]
    destination_addresses = [azurerm_public_ip.firewall.ip_address]
    translated_port       = 443
    translated_address    = "10.100.1.10"  # Internal LB IP
    protocols             = ["TCP"]
  }

  rule {
    name                  = "http-redirect"
    source_addresses      = ["*"]
    destination_ports     = ["80"]
    destination_addresses = [azurerm_public_ip.firewall.ip_address]
    translated_port       = 80
    translated_address    = "10.100.1.10"
    protocols             = ["TCP"]
  }
}
```

---

## Multi-Region Considerations

### Active-Active Setup

```
                        +------------------+
                        |   Azure Traffic  |
                        |     Manager      |
                        +--------+---------+
                                 |
              +------------------+------------------+
              |                                     |
              v                                     v
    +-------------------+                 +-------------------+
    | West Europe       |                 | North Europe      |
    | AKS Cluster       |                 | AKS Cluster       |
    | Envoy Gateway     |                 | Envoy Gateway     |
    | IP: 20.x.x.x      |                 | IP: 20.y.y.y      |
    +-------------------+                 +-------------------+
```

#### Traffic Manager Configuration

```hcl
resource "azurerm_traffic_manager_profile" "envoy_gateway" {
  name                   = "tm-envoy-gateway-prod"
  resource_group_name    = azurerm_resource_group.global.name
  traffic_routing_method = "Performance"  # Route to closest region

  dns_config {
    relative_name = "platform"
    ttl           = 60
  }

  monitor_config {
    protocol                     = "HTTPS"
    port                         = 443
    path                         = "/healthz"
    interval_in_seconds          = 30
    timeout_in_seconds           = 10
    tolerated_number_of_failures = 3
  }
}

resource "azurerm_traffic_manager_azure_endpoint" "west_europe" {
  name                 = "west-europe"
  profile_id           = azurerm_traffic_manager_profile.envoy_gateway.id
  target_resource_id   = azurerm_public_ip.envoy_west.id
  weight               = 100
  priority             = 1
}

resource "azurerm_traffic_manager_azure_endpoint" "north_europe" {
  name                 = "north-europe"
  profile_id           = azurerm_traffic_manager_profile.envoy_gateway.id
  target_resource_id   = azurerm_public_ip.envoy_north.id
  weight               = 100
  priority             = 2
}
```

### Active-Passive (DR) Setup

```yaml
# Primary cluster: All traffic
# DR cluster: Standby, receives traffic only during failover

# Traffic Manager with Priority routing
traffic_routing_method = "Priority"

# Primary: priority = 1
# DR: priority = 2 (only receives traffic if primary is unhealthy)
```

---

## Cost Optimization

### Load Balancer Costs

| Component | Cost Factor | Optimization |
|-----------|-------------|--------------|
| Standard LB | Per rule (~$18/month) | Consolidate to fewer Gateways |
| Data processed | Per GB | N/A |
| Public IP (Standard) | ~$3.65/month | Use fewer static IPs |

### Recommendations for 60 Clusters

1. **Shared Gateway Pattern**: Use one Gateway per cluster for most apps (1 LB rule set)
2. **Dedicated Gateway**: Only for isolated apps (ArgoCD, Vault)
3. **Internal LB**: For internal-only services (no public IP cost)
4. **Reserved IPs**: Pre-provision IPs to avoid churn

### Example Cost Breakdown

```
Per Cluster:
  - 1 Standard LB with 2 rules (HTTP/HTTPS): ~$36/month
  - 1 Static Public IP: ~$4/month
  - Data processing: Variable

60 Clusters:
  - LB + IP: 60 * $40 = $2,400/month
  - Estimated total: ~$2,500-3,000/month for ingress infrastructure
```

---

## Troubleshooting Azure Issues

### Common Issues and Solutions

#### Issue: Service stuck in Pending (no External IP)

```bash
# Check events
kubectl describe svc -n envoy-gateway-system envoy-argocd-gateway-xxx

# Common causes:
# 1. Public IP not found
# 2. AKS identity lacks permissions
# 3. Resource group name incorrect
```

**Solution:**
```bash
# Verify Public IP exists
az network public-ip show -g rg-networking-prod -n pip-envoy-gateway-prod

# Check AKS managed identity permissions
az role assignment list --assignee <aks-identity-object-id> --scope <pip-resource-id>
```

#### Issue: Health probe failures

```bash
# Check Azure LB health probe status
az network lb probe show -g MC_xxx -n xxx --lb-name kubernetes

# Verify Envoy pod is healthy
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/ready
```

#### Issue: Traffic not reaching Envoy pods

```bash
# Check NSG rules
az network nsg rule list -g rg-aks-prod -n nsg-aks-nodes -o table

# Verify NodePort is open
kubectl get svc -n envoy-gateway-system -o yaml | grep nodePort

# Test from Azure VM in same VNET
curl -v http://<node-ip>:<nodeport>/healthz
```

#### Issue: Cross-subscription Public IP not working

```bash
# Verify RBAC assignment
az role assignment list --scope <pip-resource-id> --query "[?principalId=='<aks-identity>']"

# Required role: Network Contributor on the Public IP
```

### Diagnostic Commands

```bash
# Get LoadBalancer events from Azure
az monitor activity-log list \
  --resource-group MC_xxx \
  --resource-type Microsoft.Network/loadBalancers \
  --start-time 2025-01-01T00:00:00Z

# Check Public IP association
az network public-ip show -g rg-networking-prod -n pip-envoy-gateway-prod \
  --query "{ip:ipAddress, associated:ipConfiguration.id}"

# List all LoadBalancer rules
az network lb rule list -g MC_xxx --lb-name kubernetes -o table
```

---

## Related Documentation

- [ARCHITECTURE.md](./ARCHITECTURE.md) - Overall architecture
- [OPERATIONS.md](./OPERATIONS.md) - Day-2 operations
- [Azure Load Balancer Documentation](https://learn.microsoft.com/en-us/azure/load-balancer/)
- [AKS Networking](https://learn.microsoft.com/en-us/azure/aks/concepts-network)
