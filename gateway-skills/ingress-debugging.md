# ingress debugging skill - systematic kubernetes ingress troubleshooting

systematic workflow for debugging kubernetes ingress issues, especially in clusters with multiple ingress controllers (nginx + envoy + traefik coexistence).

source: `./ingress_debug/`

---

## when to use

- requests returning 404 with correct dns
- wrong certificate being served
- multiple ingress controllers and unclear which handles what
- migrating from one ingress to another (e.g., nginx → envoy gateway)
- dns points to wrong loadbalancer ip
- ingress shows up in `kubectl get` but doesn't work

---

## debug workflow (systematic)

### step 1: what ingress classes exist?

```bash
# list all ingress classes
kubectl get ingressclass

# show controller mapping + default
kubectl get ingressclass -o custom-columns=NAME:.metadata.name,CONTROLLER:.spec.controller,DEFAULT:.metadata.annotations."ingressclass\.kubernetes\.io/is-default-class"

# full details
kubectl get ingressclass -o yaml
```

**red flag**: multiple classes marked `is-default-class=true` → unpredictable routing.

### step 2: what ingress resources exist?

```bash
# all ingresses with class mapping
kubectl get ingress -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.ingressClassName,HOSTS:.spec.rules[*].host,ADDRESS:.status.loadBalancer.ingress[*].ip

# find ingresses WITHOUT explicit class (uses default)
kubectl get ingress -A -o json | jq -r '.items[] | select(.spec.ingressClassName == null) | "\(.metadata.namespace)/\(.metadata.name)"'

# find ingresses using DEPRECATED annotation
kubectl get ingress -A -o json | jq -r '.items[] | select(.metadata.annotations["kubernetes.io/ingress.class"] != null) | "\(.metadata.namespace)/\(.metadata.name): \(.metadata.annotations["kubernetes.io/ingress.class"])"'

# find by specific class
kubectl get ingress -A -o json | jq -r '.items[] | select(.spec.ingressClassName == "nginx") | "\(.metadata.namespace)/\(.metadata.name)"'
```

### step 3: which controllers are deployed?

```bash
# deployments
kubectl get deploy -A | grep -iE "nginx|ingress|traefik|envoy"

# daemonsets
kubectl get ds -A | grep -iE "nginx|ingress|traefik|envoy"

# pods
kubectl get pods -A | grep -iE "nginx|ingress|traefik|envoy"

# controller args (what class does it watch?)
kubectl get deploy <controller-name> -n <namespace> -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
```

**key args to look for:**
- `--ingress-class=<class>`
- `--controller-class=<controller>`
- `--watch-ingress-without-class=true|false`

### step 4: which loadbalancers exist?

```bash
# all LoadBalancer services
kubectl get svc -A | grep LoadBalancer

# ingress controller services with ips
kubectl get svc -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,EXTERNAL-IP:.status.loadBalancer.ingress[0].ip,PORTS:.spec.ports[*].port | grep -iE "nginx|ingress|traefik|envoy"
```

### step 5: what does dns resolve to?

```bash
# basic resolution
dig +short <hostname>

# full trace
dig <hostname> +trace

# from inside the cluster
kubectl run debug --rm -it --image=busybox --restart=Never -- nslookup <hostname>.<namespace>.svc.cluster.local

# compare against known LB IPs (from step 4)
# if dns IP doesn't match any known LB IP, that's the bug
```

### step 6: controller logs for the hostname

```bash
# find controller pod
kubectl get pods -A | grep -iE "nginx.*controller|ingress.*controller"

# search logs for the hostname
kubectl logs -n <controller-ns> <controller-pod> | grep <hostname>

# all controller pods (if multi-replica)
kubectl logs -n <controller-ns> -l app.kubernetes.io/name=ingress-nginx --tail=50

# follow with timestamps
kubectl logs -n <controller-ns> <controller-pod> -f --timestamps
```

### step 7: specific ingress deep dive

```bash
# full spec
kubectl get ingress <name> -n <namespace> -o yaml

# events
kubectl describe ingress <name> -n <namespace>

# events filtered
kubectl get events -n <namespace> --field-selector involvedObject.name=<ingress-name>

# sort recent events
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20
```

### step 8: backend service/endpoints

```bash
# does service exist?
kubectl get svc <backend-service> -n <namespace>

# are pods ready? (endpoints must be populated)
kubectl get endpoints <backend-service> -n <namespace>

# detailed endpoints
kubectl describe endpoints <backend-service> -n <namespace>
```

**red flag**: empty endpoints = no healthy pods backing the service.

### step 9: tls secrets

```bash
# list tls secrets
kubectl get secrets -n <namespace> | grep tls

# check cert content
kubectl get secret <tls-secret> -n <namespace> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout

# check expiry
kubectl get secret <tls-secret> -n <namespace> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates

# check SANs (must match hostname)
kubectl get secret <tls-secret> -n <namespace> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | grep -A 1 "Subject Alternative"
```

---

## common issues & fixes

### issue 1: wrong controller handling ingress

**symptoms**:
- curl returns wrong server banner
- 404s with correct dns
- wrong tls certificate

**debug**:
```bash
# 1. what's my ingress class?
kubectl get ingress <name> -n <ns> -o jsonpath='{.spec.ingressClassName}'

# 2. which controller handles that class?
kubectl get ingressclass <class> -o jsonpath='{.spec.controller}'

# 3. which controller deployment matches?
kubectl get deploy -A -o yaml | grep -B 5 "controller-name: <controller>"
```

**fix**:
```bash
# set correct class
kubectl patch ingress <name> -n <ns> --type=merge \
  -p '{"spec":{"ingressClassName":"nginx-internal"}}'
```

### issue 2: dns points to wrong controller

**symptoms**: dns resolves to ip that's NOT the intended controller's LB ip

**debug**:
```bash
dig +short <hostname>
kubectl get svc -A -o custom-columns=NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[0].ip | grep -iE "nginx|ingress"
```

**fix**: update dns record in dns provider (route53, azure dns, cloudflare) to correct controller's external ip.

### issue 3: no ingress class specified

**symptoms**: ingress handled by default controller (might not be what you want)

**debug**:
```bash
kubectl get ingress -A -o json | jq -r '.items[] | select(.spec.ingressClassName == null) | "\(.metadata.namespace)/\(.metadata.name)"'
```

**fix**: always set `ingressClassName` explicitly.

```bash
kubectl patch ingress <name> -n <ns> --type=merge \
  -p '{"spec":{"ingressClassName":"your-class"}}'
```

### issue 4: multiple default ingress classes

**symptoms**: unpredictable routing for ingresses without explicit class

**debug**:
```bash
kubectl get ingressclass -o custom-columns=NAME:.metadata.name,DEFAULT:.metadata.annotations."ingressclass\.kubernetes\.io/is-default-class" | grep true
# if more than one row = problem
```

**fix**: remove default annotation from wrong class
```bash
kubectl annotate ingressclass <class-name> \
  ingressclass.kubernetes.io/is-default-class-
```

### issue 5: deprecated annotation still in use

**symptoms**: ingress uses `kubernetes.io/ingress.class` annotation (deprecated in k8s 1.18+)

**debug**:
```bash
kubectl get ingress -A -o json | jq -r '.items[] | select(.metadata.annotations["kubernetes.io/ingress.class"] != null) | "\(.metadata.namespace)/\(.metadata.name)"'
```

**fix**: migrate to `spec.ingressClassName`
```bash
# add new spec field
kubectl patch ingress <name> -n <ns> --type=merge \
  -p '{"spec":{"ingressClassName":"nginx"}}'

# remove deprecated annotation
kubectl annotate ingress <name> -n <ns> kubernetes.io/ingress.class-
```

### issue 6: 502 bad gateway

**symptoms**: ingress controller responds but backend returns error

**debug**:
```bash
# backend service exists?
kubectl get svc <backend> -n <ns>

# backend has healthy endpoints?
kubectl get endpoints <backend> -n <ns>

# backend pods running?
kubectl get pods -n <ns> -l <backend-selector>

# test backend directly (bypass ingress)
kubectl run debug --rm -it --image=curlimages/curl -- \
  curl -v http://<backend>.<ns>.svc.cluster.local

# 6a. check networkpolicy blocking traffic
kubectl get networkpolicy -A
kubectl describe networkpolicy -n <backend-ns>

# ingress controller often can't reach backend pods due to netpol:
# verify ingress controller namespace is allowed in backend networkpolicy
```

**common causes**:
- backend pods crashed / not ready
- service selector doesn't match pod labels
- wrong port in ingress (http vs https, or wrong port number)
- backend only accepts https but ingress uses http
- networkpolicy blocking traffic from the ingress controller namespace

### issue 7: tls/certificate errors

**symptoms**: browser shows cert errors, or ssl_handshake failures

**debug**:
```bash
# secret exists?
kubectl get secret <tls-secret> -n <ns>

# cert valid?
kubectl get secret <tls-secret> -n <ns> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | head -20

# cert expired?
kubectl get secret <tls-secret> -n <ns> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates

# sans match hostname?
kubectl get secret <tls-secret> -n <ns> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | grep -A 1 "Subject Alternative"

# test tls from outside
openssl s_client -connect <hostname>:443 -servername <hostname> </dev/null | openssl x509 -text -noout | head -20
```

**common causes**:
- secret in wrong namespace (must be same as ingress)
- cert expired (check dates)
- hostname not in SANs (san mismatch)
- cert-manager issuer error (check Certificate/Order/Challenge resources)

### issue 8: ingress stuck "pending"

**symptoms**: ingress has no ADDRESS populated

**debug**:
```bash
# events for the ingress
kubectl describe ingress <name> -n <ns>

# controller logs
kubectl logs -n <controller-ns> -l app.kubernetes.io/name=ingress-nginx --tail=50

# lb service has ip?
kubectl get svc -n <controller-ns>

# check cloud provider:
# azure: az network lb list
# aws:   aws elb describe-load-balancers
# gcp:   gcloud compute forwarding-rules list
```

---

## cert-manager troubleshooting

if your tls secret is managed by cert-manager and missing/invalid:

```bash
# check certificate resource
kubectl get certificate -n <ns>
kubectl describe certificate <name> -n <ns>

# check pending certificate requests
kubectl get certificaterequest -n <ns>
kubectl describe certificaterequest <name> -n <ns>

# check acme orders/challenges (let's encrypt)
kubectl get order -n <ns>
kubectl get challenge -n <ns>
kubectl describe challenge <name> -n <ns>

# cert-manager logs
kubectl logs -n cert-manager deploy/cert-manager --tail=100 | grep <hostname>

# clusterissuer / issuer status
kubectl get clusterissuer
kubectl describe clusterissuer <name>
```

**common issues:**
- dns01 challenge: dns propagation delay
- http01 challenge: ingress misconfigured, can't reach /.well-known/acme-challenge/
- rate limit: let's encrypt production has strict limits (use staging first!)

---

## nginx admission webhook rejections

nginx 1.9+ includes an admission webhook that validates ingress configs. common rejections:

```bash
# check webhook status
kubectl get validatingwebhookconfiguration | grep nginx

# snippet annotations blocked by default in recent versions:
# nginx.ingress.kubernetes.io/configuration-snippet -> blocked unless --allow-snippet-annotations=true
# nginx.ingress.kubernetes.io/server-snippet -> blocked by default

# regex paths require explicit opt-in:
kubectl annotate ingress <name> -n <ns> nginx.ingress.kubernetes.io/use-regex=true

# https backend:
kubectl annotate ingress <name> -n <ns> nginx.ingress.kubernetes.io/backend-protocol=HTTPS

# check webhook logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=50 | grep -i admission
```

---

## pathType differences

| pathType | description | nginx behavior | envoy gateway |
|----------|-------------|----------------|---------------|
| Exact | exact path match | exact | Exact match type |
| Prefix | prefix match | prefix | PathPrefix match type |
| ImplementationSpecific | controller-defined | treats as Prefix by default | not supported |

```bash
# regex paths (nginx only) require annotation:
kubectl annotate ingress <name> nginx.ingress.kubernetes.io/use-regex=true
```

---

## externalTrafficPolicy: Local health check failures

if using `externalTrafficPolicy: Local` (for source ip preservation):
- LB health checks only pass on nodes that have a controller pod
- without sufficient replicas, some nodes fail health checks
- LB marks them unhealthy -> traffic concentration

```bash
# check
kubectl get svc <controller-svc> -n <ctrl-ns> -o jsonpath='{.spec.externalTrafficPolicy}'
```

**fix options:**
1. scale controller to DaemonSet (one per node)
2. switch to externalTrafficPolicy: Cluster (loses source ip)
3. use LB with direct server return

---

## debugging from inside the cluster

```bash
# start debug pod
kubectl run debug --rm -it --image=curlimages/curl -- sh

# from inside debug pod:
curl -v http://<service>.<namespace>.svc.cluster.local
curl -v http://<ingress-controller-service>.<namespace>.svc.cluster.local

# with host header (bypass dns)
curl -v -H "Host: <hostname>" http://<lb-ip>/

# test a specific path
curl -v --resolve <hostname>:443:<lb-ip> https://<hostname>/path

# dns lookup inside cluster
kubectl run debug --rm -it --image=busybox --restart=Never -- nslookup <service>.<namespace>.svc.cluster.local
```

---

## comparing two ingress controllers (side by side)

```bash
# which class each watches
echo "=== controller 1 ===" && \
kubectl get deploy <controller1> -n <ns1> -o yaml | grep -E "ingress-class|controller-class" && \
echo "=== controller 2 ===" && \
kubectl get deploy <controller2> -n <ns2> -o yaml | grep -E "ingress-class|controller-class"

# which external ip each has
kubectl get svc -A -o custom-columns=NAME:.metadata.name,EXTERNAL-IP:.status.loadBalancer.ingress[0].ip | grep -iE "nginx|ingress|envoy"

# which ingresses attach to which controller
kubectl get ingress -A -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.ingressClassName
```

---

## quick fixes (one-liners)

```bash
# set ingress class
kubectl patch ingress <name> -n <ns> --type=merge -p '{"spec":{"ingressClassName":"nginx"}}'

# remove deprecated annotation
kubectl annotate ingress <name> -n <ns> kubernetes.io/ingress.class-

# force controller re-read (restart the controller pods)
kubectl rollout restart deploy/ingress-nginx-controller -n ingress-nginx
# or for envoy gateway
kubectl rollout restart deploy/envoy-gateway -n envoy-gateway-system
# note: adding an annotation does NOT reliably trigger resync on all controllers.

# remove default from class
kubectl annotate ingressclass <class> ingressclass.kubernetes.io/is-default-class-

# set default class
kubectl annotate ingressclass <class> ingressclass.kubernetes.io/is-default-class=true
```

---

## full debug sequence (copy-paste)

```bash
#!/bin/bash
# usage: ./debug.sh <hostname> <namespace> [<ingress-name>]
# ingress-name is required when the namespace has multiple ingresses
HOST=$1
NS=$2
ING=$3

echo "=== 1. ingress classes ==="
kubectl get ingressclass

echo "=== 2. ingress in namespace ==="
kubectl get ingress -n $NS -o yaml | grep -E "name:|ingressClassName:|host:|ingress.class"

echo "=== 3. controller for class ==="
if [ -n "$ING" ]; then
  CLASS=$(kubectl get ingress $ING -n $NS -o jsonpath='{.spec.ingressClassName}')
else
  CLASS=$(kubectl get ingress -n $NS -o jsonpath='{.items[0].spec.ingressClassName}')
fi
kubectl get ingressclass $CLASS -o jsonpath='{.spec.controller}'
echo ""

echo "=== 4. controller services ==="
kubectl get svc -A | grep -iE "nginx|ingress|envoy"

echo "=== 5. dns resolution ==="
dig +short $HOST

echo "=== 6. controller logs for host ==="
# detect controller type dynamically across known labels
CTRL_TYPE=$(kubectl get pods -A -l 'app.kubernetes.io/name in (ingress-nginx,envoy,envoy-gateway,traefik,contour)' -o jsonpath='{.items[0].metadata.labels.app\.kubernetes\.io/name}' 2>/dev/null)
if [ -z "$CTRL_TYPE" ]; then
  echo "warn: could not detect controller via known labels; skipping log grep"
else
  POD=$(kubectl get pods -A -l app.kubernetes.io/name=$CTRL_TYPE -o jsonpath='{.items[0].metadata.name}')
  CTRL_NS=$(kubectl get pods -A -l app.kubernetes.io/name=$CTRL_TYPE -o jsonpath='{.items[0].metadata.namespace}')
  kubectl logs -n $CTRL_NS $POD 2>/dev/null | grep $HOST | tail -10
fi

echo "=== 7. backend endpoints ==="
if [ -n "$ING" ]; then
  BACKEND=$(kubectl get ingress $ING -n $NS -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.name}')
else
  BACKEND=$(kubectl get ingress -n $NS -o jsonpath='{.items[0].spec.rules[0].http.paths[0].backend.service.name}')
fi
kubectl get endpoints $BACKEND -n $NS

echo "=== 8. tls cert ==="
if [ -n "$ING" ]; then
  TLS_SECRET=$(kubectl get ingress $ING -n $NS -o jsonpath='{.spec.tls[0].secretName}')
else
  TLS_SECRET=$(kubectl get ingress -n $NS -o jsonpath='{.items[0].spec.tls[0].secretName}')
fi
if [ -n "$TLS_SECRET" ]; then
  kubectl get secret $TLS_SECRET -n $NS -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
fi

echo "=== 9. test directly ==="
echo "curl -v --resolve $HOST:443:<controller-ip> https://$HOST/"
```

---

## cheatsheet: key differences - ingress vs gateway api

when migrating from ingress to gateway api (envoy gateway, istio gateway), remember:

| concept | ingress | gateway api |
|---------|---------|-------------|
| selector | `ingressClassName` | `parentRefs` → Gateway |
| tls | `spec.tls` on Ingress | `listeners.tls` on Gateway |
| path matching | `pathType: Prefix|Exact` | `matches.path.type: PathPrefix|Exact` |
| hostname | `rules[].host` | `hostnames` on Route |
| annotations | controller-specific | some annotations still apply on Gateway/HTTPRoute (external-dns, cert-manager), but traffic policies move to CRDs (ClientTrafficPolicy, BackendTrafficPolicy, SecurityPolicy) |
| grpc support | annotation hacks | native GRPCRoute |
| rate limiting | annotation | SecurityPolicy |
| redirects | annotation | filters |

when debugging migration issues, both systems can coexist - check both!
