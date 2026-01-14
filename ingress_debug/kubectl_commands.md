# Ingress Debug kubectl Commands

## Ingress Classes

```bash
# List all ingress classes
kubectl get ingressclass

# Show which controller handles each class
kubectl get ingressclass -o custom-columns=NAME:.metadata.name,CONTROLLER:.spec.controller,DEFAULT:.metadata.annotations."ingressclass\.kubernetes\.io/is-default-class"

# Full details
kubectl get ingressclass -o yaml

# Check specific class
kubectl describe ingressclass <class-name>
```

## Ingress Resources

```bash
# List all ingresses
kubectl get ingress -A

# Show ingress with class mapping
kubectl get ingress -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.ingressClassName,HOSTS:.spec.rules[*].host,ADDRESS:.status.loadBalancer.ingress[*].ip

# Check specific ingress
kubectl get ingress <name> -n <namespace> -o yaml
kubectl describe ingress <name> -n <namespace>

# Find ingresses without explicit class (will use default)
kubectl get ingress -A -o json | jq -r '.items[] | select(.spec.ingressClassName == null) | "\(.metadata.namespace)/\(.metadata.name)"'

# Find ingresses using deprecated annotation
kubectl get ingress -A -o json | jq -r '.items[] | select(.metadata.annotations["kubernetes.io/ingress.class"] != null) | "\(.metadata.namespace)/\(.metadata.name): \(.metadata.annotations["kubernetes.io/ingress.class"])"'

# Find ingresses by class
kubectl get ingress -A -o json | jq -r '.items[] | select(.spec.ingressClassName == "nginx") | "\(.metadata.namespace)/\(.metadata.name)"'
```

## Ingress Controllers

```bash
# Find controller deployments
kubectl get deploy -A | grep -iE "nginx|ingress"

# Find controller daemonsets
kubectl get ds -A | grep -iE "nginx|ingress"

# Find controller pods
kubectl get pods -A | grep -iE "nginx|ingress"

# Check controller args (what class it watches)
kubectl get deploy <controller-name> -n <namespace> -o yaml | grep -E "ingress-class|controller-class"

# Full deployment details
kubectl describe deploy <controller-name> -n <namespace>

# Controller container args
kubectl get deploy <controller-name> -n <namespace> -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
```

## Services & LoadBalancers

```bash
# All LoadBalancer services
kubectl get svc -A | grep LoadBalancer

# Ingress controller services
kubectl get svc -A | grep -iE "nginx|ingress"

# Get external IPs
kubectl get svc -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,EXTERNAL-IP:.status.loadBalancer.ingress[0].ip,PORTS:.spec.ports[*].port | grep -iE "nginx|ingress|NAMESPACE"

# Service details
kubectl describe svc <service-name> -n <namespace>

# Service endpoints
kubectl get endpoints <service-name> -n <namespace>
```

## Controller Logs

```bash
# Get controller pod name
kubectl get pods -A | grep -iE "nginx.*controller|ingress.*controller"

# Tail logs
kubectl logs -n <namespace> <pod-name> --tail=100

# Follow logs
kubectl logs -n <namespace> <pod-name> -f

# Logs with timestamps
kubectl logs -n <namespace> <pod-name> --timestamps --tail=100

# Search for specific host in logs
kubectl logs -n <namespace> <pod-name> | grep "argocd"

# Logs from all controller pods (if multiple replicas)
kubectl logs -n <namespace> -l app.kubernetes.io/name=ingress-nginx --tail=50
```

## ConfigMaps

```bash
# Find controller configmaps
kubectl get cm -A | grep -iE "nginx|ingress"

# View configmap
kubectl get cm <configmap-name> -n <namespace> -o yaml

# Check nginx config
kubectl describe cm <controller-configmap> -n <namespace>
```

## Events

```bash
# Events for specific ingress
kubectl get events -n <namespace> --field-selector involvedObject.name=<ingress-name>

# All ingress-related events
kubectl get events -A | grep -i ingress

# Recent events sorted
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20
```

## Backend Services Check

```bash
# Check if backend service exists
kubectl get svc <backend-service> -n <namespace>

# Check endpoints (are pods ready?)
kubectl get endpoints <backend-service> -n <namespace>

# Describe endpoints
kubectl describe endpoints <backend-service> -n <namespace>
```

## Certificates & TLS

```bash
# List secrets (TLS certs)
kubectl get secrets -n <namespace> | grep tls

# Check certificate secret
kubectl get secret <tls-secret-name> -n <namespace> -o yaml

# Decode and view cert
kubectl get secret <tls-secret-name> -n <namespace> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout

# Check cert expiry
kubectl get secret <tls-secret-name> -n <namespace> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
```

## Debugging from Inside Cluster

```bash
# Run debug pod
kubectl run debug --rm -it --image=curlimages/curl -- sh

# From inside debug pod:
curl -v http://<service-name>.<namespace>.svc.cluster.local
curl -v http://<ingress-controller-service>.<namespace>.svc.cluster.local

# DNS lookup inside cluster
kubectl run debug --rm -it --image=busybox -- nslookup <service-name>.<namespace>.svc.cluster.local
```

## Quick Fixes

```bash
# Set ingress class
kubectl patch ingress <name> -n <namespace> --type=merge -p '{"spec":{"ingressClassName":"nginx"}}'

# Remove deprecated annotation
kubectl annotate ingress <name> -n <namespace> kubernetes.io/ingress.class-

# Add annotation (if controller requires it)
kubectl annotate ingress <name> -n <namespace> kubernetes.io/ingress.class=nginx

# Force controller re-sync (add/update annotation)
kubectl annotate ingress <name> -n <namespace> debug-timestamp="$(date +%s)" --overwrite

# Remove default from ingress class
kubectl annotate ingressclass <class-name> ingressclass.kubernetes.io/is-default-class-

# Set default ingress class
kubectl annotate ingressclass <class-name> ingressclass.kubernetes.io/is-default-class=true
```

## Compare Two Controllers

```bash
# Side by side - which class each watches
echo "=== Controller 1 ===" && \
kubectl get deploy <controller1> -n <ns1> -o yaml | grep -E "ingress-class|controller-class" && \
echo "=== Controller 2 ===" && \
kubectl get deploy <controller2> -n <ns2> -o yaml | grep -E "ingress-class|controller-class"

# Which external IP each has
kubectl get svc -A -o custom-columns=NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[0].ip | grep -iE "nginx|ingress"
```

## Full Debug Sequence

```bash
# 1. Check what classes exist
kubectl get ingressclass

# 2. Check your ingress
kubectl get ingress <name> -n <namespace> -o yaml | grep -E "ingressClassName|ingress.class"

# 3. Find which controller handles that class
kubectl get ingressclass <class-from-step-2> -o jsonpath='{.spec.controller}'

# 4. Find that controller's service/IP
kubectl get svc -A | grep -iE "nginx|ingress"

# 5. Check DNS points to right IP
dig +short <your-hostname>

# 6. Check controller logs for your host
kubectl logs -n <controller-namespace> <controller-pod> | grep <your-hostname>
```
