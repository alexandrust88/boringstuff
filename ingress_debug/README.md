# Ingress Debug Tools

Scripts for debugging Kubernetes ingress routing issues, especially when multiple ingress controllers exist.

## Quick Start

```bash
# Make scripts executable
chmod +x *.sh

# Run full debug for a hostname
./09_full_debug.sh argocd.example.com my-context argocd
```

## Scripts

| Script | Purpose | Usage |
|--------|---------|-------|
| `01_dns_debug.sh` | DNS resolution checks | `./01_dns_debug.sh <hostname>` |
| `02_ingress_classes.sh` | List all ingress classes | `./02_ingress_classes.sh [context]` |
| `03_ingresses.sh` | List all ingress resources | `./03_ingresses.sh [context] [namespace]` |
| `04_ingress_controllers.sh` | Find controller deployments/pods | `./04_ingress_controllers.sh [context]` |
| `05_specific_ingress.sh` | Deep dive on one ingress | `./05_specific_ingress.sh <ns> <name> [context]` |
| `06_controller_logs.sh` | Get controller logs | `./06_controller_logs.sh [context] [lines]` |
| `07_loadbalancer_ips.sh` | Map LB IPs to controllers | `./07_loadbalancer_ips.sh [context]` |
| `08_endpoint_test.sh` | Test connectivity | `./08_endpoint_test.sh <hostname> [expected-ip]` |
| `09_full_debug.sh` | Run all scripts | `./09_full_debug.sh <hostname> [context] [ns]` |
| `10_compare_controllers.sh` | Compare two controllers | `./10_compare_controllers.sh [context]` |
| `11_fix_suggestions.sh` | Suggest fixes | `./11_fix_suggestions.sh <ns> <ingress> [context]` |

## Common Issues

### 1. Wrong Controller Handling Ingress

**Symptoms**: Curl shows wrong server, 404s, or wrong certificate

**Debug**:
```bash
./02_ingress_classes.sh my-context    # List classes
./10_compare_controllers.sh my-context # Compare controllers
./05_specific_ingress.sh argocd argocd-server my-context
```

**Fix**: Ensure `spec.ingressClassName` is set correctly:
```bash
kubectl patch ingress <name> -n <ns> --type=merge \
  -p '{"spec":{"ingressClassName":"nginx-internal"}}'
```

### 2. DNS Points to Wrong Controller

**Symptoms**: DNS resolves to wrong IP

**Debug**:
```bash
./01_dns_debug.sh argocd.example.com
./07_loadbalancer_ips.sh my-context
```

**Fix**: Update DNS to point to correct controller's external IP

### 3. No Ingress Class Specified

**Symptoms**: Ingress handled by default controller (might be wrong one)

**Debug**:
```bash
./03_ingresses.sh my-context
# Look for ingresses without class
```

**Fix**:
```bash
kubectl patch ingress <name> -n <ns> --type=merge \
  -p '{"spec":{"ingressClassName":"your-class"}}'
```

### 4. Multiple Default Classes

**Debug**:
```bash
./10_compare_controllers.sh my-context
# Check for "WARNING: Multiple default ingress classes"
```

**Fix**: Remove default annotation from wrong class:
```bash
kubectl annotate ingressclass <class-name> \
  ingressclass.kubernetes.io/is-default-class-
```

## Switching Contexts

All scripts accept context as first or second argument:

```bash
# Specify context explicitly
./02_ingress_classes.sh prod-cluster
./03_ingresses.sh prod-cluster argocd
./05_specific_ingress.sh argocd argocd-server prod-cluster
```

## ArgoCD Specific

For ArgoCD ingress issues:
```bash
# Full debug
./09_full_debug.sh argocd.example.com my-context argocd

# Check specific ingress
./05_specific_ingress.sh argocd argocd-server my-context

# Get fix suggestions
./11_fix_suggestions.sh argocd argocd-server my-context
```
