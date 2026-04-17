# envoy gateway skill

comprehensive skill for deploying, configuring, operating, and troubleshooting envoy gateway on kubernetes using the gateway api.

---

## overview

envoy gateway is a kubernetes-native gateway api implementation built on envoy proxy. it replaces traditional ingress controllers (nginx, traefik) with the standard gateway api resource model.

**source repo**: `./`

## when to use this skill

- deploying envoy gateway on kubernetes clusters
- creating gateway, httproute, grpcroute, tcproute resources
- configuring tls termination, http-to-https redirects
- setting up policies (client traffic, backend traffic, security)
- migrating from ingress controllers to gateway api
- troubleshooting envoy proxy issues (500s, 502s, tls, grpc)
- configuring argocd with envoy gateway (ui + grpc cli)
- setting up monitoring, alerting, and observability for envoy
- multi-cluster gateway deployments with gitops (argocd)

## architecture

### control plane / data plane separation

```
control plane (envoy-gateway-system namespace)
  envoy-gateway controller (deployment, 2+ replicas, leader election)
    watches: GatewayClass, Gateway, HTTPRoute, GRPCRoute, *Policy, Service, Secret
    generates: xDS configuration
    manages: envoy proxy deployments, services, configmaps

data plane (per-gateway envoy proxy fleet)
  per gateway resource, controller creates:
    deployment: envoy proxy pods (3+ for production)
    service: LoadBalancer (external) or ClusterIP (internal)
    configmap: bootstrap configuration
  envoy receives config via xDS (gRPC ADS) - hot-reload, no restart needed
```

### gateway api resource hierarchy

```
GatewayClass (cluster-scoped)
  controls which controller handles gateways
  one per envoy gateway installation (typically named "eg")
  can reference EnvoyProxy CRD for custom proxy config
    |
    v
Gateway (namespace-scoped)
  defines listeners (ports, protocols, tls)
  each gateway = separate envoy proxy fleet + loadbalancer
  protocols: HTTP, HTTPS, TLS (passthrough), TCP, UDP
    |
    v
HTTPRoute / GRPCRoute / TCPRoute (namespace-scoped)
  defines routing rules to backend services
  attached to gateway via parentRefs
  match on: path, headers, query params, method
    |
    v
BackendRef -> Service (backend pods)
```

### policy attachment model

policies attach to gateways or routes to add behavior:

| policy | attaches to | purpose |
|--------|-------------|---------|
| ClientTrafficPolicy | Gateway | http/2, tcp keepalive, tls settings, connection limits |
| BackendTrafficPolicy | HTTPRoute | retries, timeouts, circuit breaker, health checks, load balancing |
| SecurityPolicy | HTTPRoute | cors, rate limiting, jwt auth, ip allowlisting |
| BackendTLSPolicy | Service | mtls to backend (when backend requires https) |

### envoy proxy pod anatomy

```
envoy proxy pod:
  container: envoy
    port 8080: HTTP listener
    port 8443: HTTPS listener
    port 19001: admin interface (metrics, config_dump, clusters)
    volumes: /etc/envoy (bootstrap), /certs (tls secrets)
    xDS connection: -> envoy-gateway.envoy-gateway-system:18000

  container: shutdown-manager
    handles graceful shutdown during rolling updates
```

## helm chart patterns

### wrapper chart pattern (recommended for multi-cluster)

```yaml
# Chart.yaml
apiVersion: v2
name: envoy-gateway-wrapper
version: 1.0.0
dependencies:
  - name: gateway-helm
    version: "1.2.x"
    repository: "oci://docker.io/envoyproxy/gateway-helm"
```

### key values.yaml structure

```yaml
envoy-gateway:
  deployment:
    envoyGateway:
      replicas: 2                    # controller HA (leader election)
      resources:
        requests: { cpu: 100m, memory: 256Mi }
        limits: { cpu: 500m, memory: 1Gi }
      podDisruptionBudget:
        minAvailable: 1

  config:
    envoyGateway:
      gateway:
        controllerName: gateway.envoyproxy.io/gatewayclass-controller
      provider:
        type: Kubernetes
        kubernetes:
          envoyDeployment:
            replicas: 2              # data plane replicas
            container:
              resources:
                requests: { cpu: 200m, memory: 256Mi }
                limits: { cpu: 1000m, memory: 1Gi }
          envoyService:
            type: LoadBalancer
            externalTrafficPolicy: Local
          envoyHpa:
            minReplicas: 2
            maxReplicas: 10
            metrics:
              - type: Resource
                resource:
                  name: cpu
                  target: { type: Utilization, averageUtilization: 80 }
```

### production values overlay

```yaml
# values-prod.yaml
envoy-gateway:
  deployment:
    envoyGateway:
      replicas: 3
      resources:
        requests: { cpu: 250m, memory: 512Mi }
        limits: { cpu: 1000m, memory: 2Gi }
      podDisruptionBudget:
        minAvailable: 2

  config:
    envoyGateway:
      provider:
        kubernetes:
          envoyDeployment:
            replicas: 3
            pod:
              annotations:
                prometheus.io/scrape: "true"
                prometheus.io/port: "19001"
                prometheus.io/path: "/stats/prometheus"
              affinity:
                podAntiAffinity:
                  requiredDuringSchedulingIgnoredDuringExecution:
                    - labelSelector:
                        matchLabels:
                          app.kubernetes.io/name: envoy
                      topologyKey: kubernetes.io/hostname
                  preferredDuringSchedulingIgnoredDuringExecution:
                    - weight: 100
                      podAffinityTerm:
                        labelSelector:
                          matchLabels:
                            app.kubernetes.io/name: envoy
                        topologyKey: topology.kubernetes.io/zone
              topologySpreadConstraints:
                - maxSkew: 1
                  topologyKey: topology.kubernetes.io/zone
                  whenUnsatisfiable: ScheduleAnyway
                  labelSelector:
                    matchLabels:
                      app.kubernetes.io/name: envoy
            container:
              resources:
                requests: { cpu: 500m, memory: 512Mi }
                limits: { cpu: 2000m, memory: 2Gi }
          envoyHpa:
            minReplicas: 3
            maxReplicas: 20

monitoring:
  enabled: true
  serviceMonitor:
    enabled: true
    interval: 15s

networkPolicies:
  enabled: true

podSecurityStandards:
  enabled: true
  level: restricted
```

## resource sizing guide

| traffic level | envoy cpu request | envoy memory request | envoy replicas |
|---------------|-------------------|----------------------|----------------|
| low (<1k rps) | 100m | 128Mi | 2 |
| medium (1-5k rps) | 250m | 256Mi | 3 |
| high (5-20k rps) | 500m | 512Mi | 5 |
| very high (>20k rps) | 1000m | 1Gi | 10+ |

## argocd gitops deployment

### app-of-apps pattern with sync waves

```yaml
# sync-wave 0: envoy gateway controller
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: envoy-gateway
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  source:
    repoURL: oci://docker.io/envoyproxy/gateway-helm
    chart: gateway-helm
    targetRevision: v1.2.0
  destination:
    namespace: envoy-gateway-system

---
# sync-wave 1: gatewayclass (depends on controller)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gateway-class
  annotations:
    argocd.argoproj.io/sync-wave: "1"

---
# sync-wave 2: gateway instances (depends on gatewayclass)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gateway-instances
  annotations:
    argocd.argoproj.io/sync-wave: "2"
```

### dependency ordering (critical)

```
GatewayClass must exist before Gateway
Gateway must exist before Routes
Services must exist before Routes (for status)
Secrets must exist before Gateway (for TLS)
```

## configuration lifecycle (zero-downtime)

```
developer creates/updates HTTPRoute
  -> controller detects change (informers)
  -> validates configuration
  -> generates intermediate representation (IR)
  -> translates IR to xDS
  -> pushes to envoy proxies via ADS (gRPC)
  -> envoy hot-reloads (no restart)
  -> controller updates resource status
```

## sub-documents

detailed guidance split across focused documents:

### envoy gateway (core)

| document | content |
|----------|---------|
| [envoy-gateway-resources.md](envoy-gateway-resources.md) | gateway api resource patterns, yaml templates, match types |
| [envoy-gateway-operations.md](envoy-gateway-operations.md) | monitoring, alerting, troubleshooting, scaling, upgrades, runbooks |
| [envoy-gateway-migration.md](envoy-gateway-migration.md) | ingress-to-gateway migration, parallel running, dns cutover |
| [envoy-gateway-argocd.md](envoy-gateway-argocd.md) | argocd-specific patterns: ui + grpc, insecure mode, helm chart |
| [envoy-gateway-security.md](envoy-gateway-security.md) | tls, cert-manager, policies, rbac, pod security, hardening |

### adjacent platform skills (from boringstuff repo)

| document | content |
|----------|---------|
| [istio-gitops.md](istio-gitops.md) | istio 1.28 via argocd app-of-apps, sync waves, hardened helm values, private registry migration |
| [cilium-observability.md](cilium-observability.md) | aks cilium 1.17 + datadog: hubble metrics (no relay), monitors, slos, capacity planning, bpf tuning |
| [kaniko-builds.md](kaniko-builds.md) | unprivileged container builds under restricted psa, kaniko vs podman vs buildah, ci/cd patterns |
| [ingress-debugging.md](ingress-debugging.md) | systematic ingress troubleshooting workflow, multi-controller coexistence, debug scripts |

## quick reference commands

```bash
# check gateway status
kubectl get gateway -A
kubectl get gateway <name> -n <ns> -o yaml | grep -A 20 status

# check route status
kubectl get httproute -A
kubectl get httproute <name> -n <ns> -o jsonpath='{.status.parents[0].conditions}' | jq .

# check envoy pods
kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=<gateway>

# envoy config dump
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/config_dump | jq .

# envoy stats
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/stats

# envoy clusters (backends)
kubectl exec -n envoy-gateway-system <envoy-pod> -- wget -qO- localhost:19001/clusters

# check controller logs
kubectl logs -n envoy-gateway-system -l control-plane=envoy-gateway --tail=100

# check envoy proxy logs
kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=<gateway> --tail=100

# test connectivity
curl -v --resolve <hostname>:443:<gateway-ip> https://<hostname>/
grpcurl -insecure <hostname>:443 list

# backup all gateway resources
kubectl get gateway,httproute,grpcroute,backendtrafficpolicy,clienttrafficpolicy,securitypolicy -A -o yaml > envoy-backup.yaml
```

## external references

- envoy gateway docs: https://gateway.envoyproxy.io/
- gateway api spec: https://gateway-api.sigs.k8s.io/
- envoy proxy docs: https://www.envoyproxy.io/docs/envoy/latest/
- gateway api crds: https://github.com/kubernetes-sigs/gateway-api/releases
- envoy gateway helm: oci://docker.io/envoyproxy/gateway-helm
