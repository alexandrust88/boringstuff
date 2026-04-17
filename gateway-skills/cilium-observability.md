# cilium observability skill - aks cilium 1.17 + datadog

configure, monitor, and operate cilium CNI with full observability via datadog. covers aks-managed cilium specifics, hubble metrics, datadog integration, and anomaly detection.

source: `./cilium_stuff/`

---

## when to use

- operating aks-managed cilium 1.17 (azure cni powered by cilium)
- configuring hubble metrics without hubble relay
- integrating cilium with datadog (monitors, slos, dashboards)
- troubleshooting cilium datapath/control plane issues
- capacity planning for bpf maps, identities, endpoints

---

## aks cilium specifics (critical differences)

on aks, **azure manages cilium**. you do NOT install via helm. knowing what's different vs self-managed cilium is critical.

| feature | aks cilium 1.17 | self-managed cilium |
|---------|----------------|---------------------|
| installation | azure-managed (az aks create) | helm |
| hubble | embedded in cilium-agent | separate relay + ui |
| hubble relay | NOT deployed | deployed (configurable) |
| hubble UI | NOT deployed | deployed (configurable) |
| clustermesh | NOT available | available |
| ipam | azure-delegated (azure VNET) | kubernetes/cluster-pool |
| kube-proxy replacement | enabled by default | configurable |
| envoy L7 proxy | NOT deployed | available |
| state storage | CRD-based | etcd or CRD |
| upgrades | az aks upgrade | helm upgrade |

### ports reference

| port | component | purpose |
|------|-----------|---------|
| 9962 | cilium-agent | prometheus metrics |
| 9963 | cilium-operator | prometheus metrics (cilium 1.12+) |
| 9965 | hubble (embedded) | per-node hubble metrics |
| 9964 | envoy L7 | **NOT on aks** |
| 9990 | cilium-agent | **GKE only** (source: unverified, per operational runbook; current gke docs may have changed - verify on your cluster) |

**note**: port 6942 is legacy (pre-cilium 1.12). for cilium 1.17 on aks, operator metrics are on 9963. verify with: `kubectl exec -n kube-system deploy/cilium-operator -- curl -s localhost:9963/metrics`

**critical**: aks does NOT expose port 9965 by default on cilium-agent pods. see [Azure/AKS#4708](https://github.com/Azure/AKS/issues/4708). verify exposure before configuring scrapes:

```bash
kubectl exec -n kube-system ds/cilium -- curl -s localhost:9965/metrics | head -5
```

if this fails, you cannot scrape hubble metrics on aks without patching. microsoft has not provided a supported persistence mechanism.

**aks envoy clarification**: aks cilium 1.17 does not ship cilium-envoy. httpV2 hubble metrics produce nothing. workaround: deploy envoy standalone (envoy gateway), not via cilium.

### check what's running

```bash
# verify cilium components
kubectl get ds -n kube-system cilium
kubectl get deploy -n kube-system cilium-operator
kubectl get cm cilium-config -n kube-system -o yaml

# check cilium version
kubectl exec -n kube-system ds/cilium -- cilium-dbg version

# verify metric endpoints
kubectl exec -n kube-system ds/cilium -- curl -s localhost:9962/metrics | head -20
kubectl exec -n kube-system ds/cilium -- curl -s localhost:9965/metrics | head -20
kubectl exec -n kube-system deploy/cilium-operator -- curl -s localhost:9963/metrics | head -20
```

---

## enabling hubble metrics on aks

aks should enable hubble by default, but plugins are minimal. patch the configmap for full observability.

### recommended hubble metric plugins

```yaml
hubble-metrics:
  - "dns:query;ignoreAAAA;labelsContext=source_namespace,destination_namespace"
  - "drop:sourceContext=namespace|reserved-identity;destinationContext=namespace|reserved-identity;labelsContext=source_namespace,destination_namespace,traffic_direction"
  - "tcp:sourceContext=namespace|reserved-identity;destinationContext=namespace|reserved-identity"
  - "flow:sourceContext=namespace|reserved-identity;destinationContext=namespace|reserved-identity;labelsContext=traffic_direction"
  - "icmp:sourceContext=namespace|reserved-identity;destinationContext=namespace|reserved-identity"
  - "policy:sourceContext=namespace|reserved-identity;destinationContext=namespace|reserved-identity;labelsContext=traffic_direction"
  - "port-distribution:sourceContext=namespace;destinationContext=namespace"
  - "flows-to-world:any-drop;port;syn-only;labelsContext=source_namespace,destination_namespace"
  # httpV2 requires envoy L7 - skip on aks unless envoy is manually configured
```

### apply via configmap patch

```bash
kubectl patch cm cilium-config -n kube-system --type merge -p '
{
  "data": {
    "hubble-metrics": "dns:query;ignoreAAAA;labelsContext=source_namespace,destination_namespace drop:sourceContext=namespace|reserved-identity;destinationContext=namespace|reserved-identity;labelsContext=source_namespace,destination_namespace,traffic_direction tcp:sourceContext=namespace|reserved-identity;destinationContext=namespace|reserved-identity flow:sourceContext=namespace|reserved-identity;destinationContext=namespace|reserved-identity;labelsContext=traffic_direction icmp:sourceContext=namespace|reserved-identity;destinationContext=namespace|reserved-identity policy:sourceContext=namespace|reserved-identity;destinationContext=namespace|reserved-identity;labelsContext=traffic_direction port-distribution:sourceContext=namespace;destinationContext=namespace flows-to-world:any-drop;port;syn-only;labelsContext=source_namespace,destination_namespace"
  }
}'

# restart to apply
kubectl rollout restart ds/cilium -n kube-system
```

**warning**: hubble-metrics in configmap expects newline-separated plugin entries. the single-string approach works for some fields but cilium documentation specifies multi-line yaml list. verify your cilium version accepts this format before relying on it. also note: aks will revert this configmap on cluster upgrade, and no `az aks` flag persists these settings today - wrap in reconciler/job or accept the drift.

### bpf configuration (best practices)

```yaml
enable-bpf-masquerade: "true"
monitor-aggregation: "medium"
monitor-aggregation-interval: "5s"
monitor-aggregation-flags: "all"
bpf-events-drop: "enabled"
bpf-events-policy-verdict: "enabled"
bpf-events-trace: "enabled"
```

---

## datadog integration

### datadog agent autodiscovery config

```yaml
# cilium-agent
ad_identifiers:
  - cilium-agent
init_config:
instances:
  - agent_endpoint: http://%%host%%:9962/metrics
    use_openmetrics: true
    namespace: cilium
    tags:
      - "cluster:your-cluster"

# hubble (embedded, per-node)
ad_identifiers:
  - cilium-agent
init_config:
instances:
  - openmetrics_endpoint: http://%%host%%:9965/metrics
    namespace: cilium_hubble
    metrics:
      - cilium_hubble_flows_processed_total
      - cilium_hubble_dns_queries_total
      - cilium_hubble_dns_responses_total
      - cilium_hubble_policy_verdicts_total
      - cilium_hubble_drop_total
      - cilium_hubble_flows_to_world_total
      - cilium_hubble_lost_events_total

# cilium-operator
ad_identifiers:
  - cilium-operator
instances:
  - agent_endpoint: http://%%host%%:9963/metrics
    use_openmetrics: true
    namespace: cilium_operator
```

### version compatibility

| component | min version | feature |
|-----------|-------------|---------|
| datadog agent | 6.15.1 | base cilium integration |
| datadog agent | 6.16.0 | `cilium.prometheus.health` service check |
| datadog agent | 7.34.0 | `cilium.openmetrics.health` service check |

### gke note

gke exposes cilium agent metrics on **port 9990** (not 9962). adjust accordingly.

---

## critical monitors (datadog)

### data plane critical (priority 1)

```yaml
# bpf map pressure critical
- name: "cilium: bpf map pressure critical"
  type: metric alert
  query: "avg(last_5m):max:cilium.bpf.map_pressure{*} by {map_name,host} > 0.9"
  thresholds:
    critical: 0.9
    warning: 0.75
  action: |
    kubectl exec -n kube-system ds/cilium -- cilium-dbg bpf ct list global | wc -l
    # increase bpf-map-dynamic-size-ratio
    # avoid resizing during peak traffic

# high drop rate
- name: "cilium: high drop rate"
  query: "sum(last_5m):sum:cilium.drop_count.count{*} by {reason,direction}.as_rate() > 100"
  # note: cilium.drop_count.count only works on datadog agent >= 7.34
  action: |
    kubectl exec -n kube-system ds/cilium -- cilium-dbg monitor --type drop

# unreachable nodes
- name: "cilium: unreachable nodes"
  query: "max(last_5m):max:cilium.unreachable.nodes{*} by {host} > 0"
  action: |
    kubectl exec -n kube-system ds/cilium -- cilium-dbg status
    kubectl exec -n kube-system ds/cilium -- cilium-dbg node list
```

### control plane critical (priority 1)

```yaml
# failing controllers
- name: "cilium: failing controllers"
  query: "max(last_5m):max:cilium.controllers.failing.count{*} by {host} > 0"

# policy import errors
- name: "cilium: policy import errors"
  query: "sum(last_10m):sum:cilium.policy.import_errors.count{*}.as_count() > 0"
  action: |
    kubectl get cnp -A | grep -v True
    kubectl get ccnp -A | grep -v True
```

**important**: do NOT add `cilium.kvstore.quorum_errors` monitor on aks - aks uses CRD-based state, not etcd.

### security monitors (priority 2)

```yaml
# policy denials spike
- name: "cilium: hubble policy denials spike"
  query: "sum(last_5m):sum:cilium.hubble.policy_verdicts_total{verdict:dropped}.as_count() > 100"
  action: |
    kubectl exec -n kube-system ds/cilium -- hubble observe --verdict DROPPED --last 50

# anomaly: external traffic (data exfiltration signal)
# note: `robust` anomaly detection is bad for low-volume metrics (flows-to-world can be sparse).
# use `agile` for sparse signals.
- name: "cilium: external traffic anomaly (flows-to-world)"
  query: >
    avg(last_20m):anomalies(sum:cilium.hubble.flows_to_world_total{*}.as_rate(),
    'agile', 3, direction='above', interval=60, alert_window='last_20m',
    count_default_zero='true', seasonality='daily') >= 1

# anomaly: dns queries (dns tunneling/dga)
- name: "cilium: dns query pattern anomaly"
  query: >
    avg(last_15m):anomalies(sum:cilium.hubble.dns_queries_total{*}.as_rate(),
    'agile', 3, direction='both', interval=60, alert_window='last_15m',
    count_default_zero='true', seasonality='daily') >= 1
```

### capacity monitors (priority 2)

```yaml
# identity count (limit: 65535)
- name: "cilium: identity count approaching limit"
  query: "max(last_15m):sum:cilium.identity.count{*} > 50000"
  action: |
    # reduce high-cardinality identity labels
    kubectl exec -n kube-system ds/cilium -- cilium-dbg identity list | wc -l

# bpf map fill forecast
- name: "cilium: bpf map fill rate projection"
  query: >
    avg(last_1h):forecast(avg:cilium.bpf.map_pressure{*} by {map_name},
    'linear', 1, interval='60m', history='1w') > 0.9
```

---

## slos

### cilium network availability (monitor-based)

```yaml
- name: "Cilium Network Availability"
  type: monitor
  monitor_ids: ["<unreachable_nodes_monitor_id>"]
  thresholds:
    - timeframe: "7d"
      target: 99.9
    - timeframe: "30d"
      target: 99.9
```

### cilium policy enforcement (metric-based)

```yaml
- name: "Cilium Policy Enforcement Success"
  type: metric
  query:
    numerator: "sum:cilium.forward_count.count{*}.as_count()"
    denominator: "sum:cilium.forward_count.count{*}.as_count() + sum:cilium.drop_count.count{*}.as_count()"
  thresholds:
    - timeframe: "30d"
      target: 99.95
```

### hubble observability coverage

```yaml
- name: "Hubble Observability Coverage"
  type: metric
  query:
    numerator: "sum:cilium.hubble.flows_processed.count{*}.as_count()"
    denominator: "sum:cilium.hubble.flows_processed.count{*}.as_count() + sum:cilium.hubble.lost_events.count{*}.as_count()"
  thresholds:
    - timeframe: "30d"
      target: 99.5
```

**note**: openmetrics strips `_total` from counter metrics. use `.count` suffix in datadog:

- `cilium.hubble.flows_processed_total` -> `cilium.hubble.flows_processed.count`
- `cilium.hubble.lost_events_total` -> `cilium.hubble.lost_events.count`

### cilium dns resolution success

```yaml
- name: "Cilium DNS Resolution Success"
  type: metric
  query:
    numerator: "sum:cilium.hubble.dns_responses.count{rcode:No Error}.as_count()"
    denominator: "sum:cilium.hubble.dns_responses.count{*}.as_count()"
  thresholds:
    - timeframe: "30d"
      target: 99.9
```

**warning**: rcode tag values vary by cilium version ('No Error' vs 'NoError' vs 'NOERROR'). verify yours:

```bash
kubectl exec -n kube-system ds/cilium -- curl -s localhost:9965/metrics | grep dns_responses
```

---

## troubleshooting

### metrics not working

```bash
# check configmap
kubectl get cm cilium-config -n kube-system -o yaml | grep -E 'prometheus|hubble|metrics'

# port-forward and test
kubectl port-forward -n kube-system ds/cilium 9962:9962 &
curl -s localhost:9962/metrics | grep cilium_endpoint
```

### datadog not scraping

```bash
# agent logs
kubectl logs -n datadog ds/datadog -c agent | grep -i cilium
kubectl logs -n datadog ds/datadog -c agent | grep -i openmetrics

# verify check loaded
kubectl exec -n datadog ds/datadog -- agent configcheck | grep cilium

# run checks manually
kubectl exec -n datadog ds/datadog -- agent check cilium
kubectl exec -n datadog ds/datadog -- agent check openmetrics
```

### bpf map pressure high

```bash
# identify which map is full
kubectl exec -n kube-system ds/cilium -- cilium-dbg bpf ct list global | wc -l

# critical maps to watch:
# - cilium_ct4_global (IPv4 conntrack)
# - cilium_ct_any4_global (any-protocol conntrack)
# - cilium_snat_v4_external (SNAT)
# - cilium_lb4_services_v2 (load balancer)
# - cilium_policy_* (per-endpoint policy maps)
```

fixes:
- tune `bpf-map-dynamic-size-ratio: 0.0025` (0.25% of node memory)
- avoid resizing during peak traffic
- check for connection leaks (stuck connections)
- enable `enable-unreachable-routes=true` to clean up stale connections

### endpoint regeneration failing

```bash
# list endpoints
kubectl exec -n kube-system ds/cilium -- cilium-dbg endpoint list

# get specific endpoint
kubectl exec -n kube-system ds/cilium -- cilium-dbg endpoint get <ID>
```

causes:
- invalid CiliumNetworkPolicy syntax
- bpf compilation errors (check cilium-agent logs)
- insufficient cpu/memory on the node
- bpf map pressure preventing map updates

### high cardinality issues

```bash
# identify highest cardinality metrics
kubectl exec -n kube-system ds/cilium -- \
  sh -c "curl -s localhost:9962/metrics | grep -v '^#' | cut -d'{' -f1 | sort | uniq -c | sort -rn | head -20"
```

fixes:
- remove `source_ip`, `destination_ip` from `labelsContext`
- disable high-cardinality metrics (e.g., `-cilium_node_connectivity_*`)
- use `exclude_metrics` in datadog confd
- increase `monitorAggregation` from `medium` to `maximum`

### policy drops

```bash
# real-time drops
kubectl exec -n kube-system ds/cilium -- cilium-dbg monitor --type drop

# hubble view
kubectl exec -n kube-system ds/cilium -- hubble observe --verdict DROPPED --last 50

# check applied policies
kubectl exec -n kube-system ds/cilium -- cilium-dbg policy get
```

---

## capacity planning

### identity capacity (limit: 65535)

```
current: sum:cilium.identity.count{*}
growth:  per_hour(derivative(sum:cilium.identity.count{*}))
days_to_limit: (65535 - current) / (growth * 24)
```

recommendations:
- compact allowlist of identity-relevant labels
- exclude high-cardinality prefixes (pod/deployment-hash labels)
- monitor identity GC frequency during churn

### bpf map capacity

critical maps:
- `cilium_ct4_global` (IPv4 conntrack)
- `cilium_ct_any4_global` (any-protocol conntrack)
- `cilium_snat_v4_external` (SNAT)
- `cilium_lb4_services_v2` (load balancer)
- `cilium_policy_*` (per-endpoint policy maps)

tuning: `bpf-map-dynamic-size-ratio: 0.0025` (0.25% of node memory)

**warning**: default 0.0025 = 0.25% of node memory. overriding downward risks maps too small. do not blindly tune; monitor current map pressure first.

### endpoint scaling

- ~250 endpoints per node (depends on resources)
- increasing regen time = cluster churn exceeding processing capacity

### ip utilization on aks

azure manages IPAM via VNET subnets. monitor via:
```bash
az network vnet subnet show --query addressPrefix
```
cilium IPAM tuning options do NOT apply on aks.

---

## scaling best practices (production)

### routing
- prefer native routing over overlays (eliminates encapsulation cost)
- define `ipv4NativeRoutingCIDR` to prevent accidental east-west SNAT

### ipam
- aks: azure-managed, monitor VNET subnet utilization
- self-managed: `pre-allocate=1` for high-density nodes, surge allocate for pending backlogs
- aws: enable IPv4 prefix delegation (/28 = 16 IPs per ENI slot)

### kube-proxy replacement
- enable maglev consistent hashing for stable backend selection
- use XDP acceleration where hardware/kernel support it
- local redirect policies for on-node DNS

### conntrack
- `enable-unreachable-routes=true` reduces blind retransmits
- monitor conntrack GC per node for localized datapath stress

### mtu
- derive pod MTU from underlying network MTU minus encapsulation
- mismatches appear as: intermittent timeouts with larger payloads, increased TCP retransmits

### hubble
- increase event-queue sizes and buffer limits for high-traffic clusters
- apply rate limits to flow events
- monitor backpressure, queue drops, processing failures

### rollouts
- stagger deployments: canary -> staging -> production
- run `cilium-dbg preflight validate-cnp` before upgrades
- use `cilium connectivity test` as validation gate

---

## upgrade preflight checklist

```bash
# validate CiliumNetworkPolicy resources
kubectl -n kube-system exec deploy/cilium-operator -- cilium-dbg preflight validate-cnp

# connectivity test (if cilium CLI installed)
cilium connectivity test

# check bpf map pressure before upgrade
kubectl exec -n kube-system ds/cilium -- cilium-dbg bpf ct list global | wc -l

# identity count headroom
kubectl exec -n kube-system ds/cilium -- cilium-dbg identity list | wc -l

# cilium version
kubectl exec -n kube-system ds/cilium -- cilium-dbg version
```

**aks note**: `cilium connectivity test` does NOT run as automatic helm hook on aks (cilium is azure-managed). run directly if cilium CLI is installed. aks doesn't support all test scenarios. skip unsupported with `--test '!pod-to-pod-encryption'` etc.

---

## references

- see `./cilium_stuff/cilium-datadog-metrics-enablement.csv` for metric -> source -> enablement mapping
- datadog-helm-values.yaml: `./cilium_stuff/datadog-helm-values.yaml`
- [Azure/AKS#4708](https://github.com/Azure/AKS/issues/4708) - aks hubble port 9965 exposure
