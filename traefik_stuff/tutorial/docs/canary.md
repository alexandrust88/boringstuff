# canary / weighted traffic

split traffic between `httpbin` (v1) and `httpbin-v2`. the nginx `canary-weight` annotation translates automatically; the native form is a `TraefikService.weighted`.

## deploy v2

```bash
kubectl apply -f canary/httpbin-v2.yaml
kubectl wait -n httpbin --for=condition=Available deploy/httpbin-v2 --timeout=120s
```

## path 1 — automatic (nginx canary annotations)

ingress-nginx does canary with a **second Ingress** on the same host, marked `canary: "true"` + `canary-weight`. traefik 3.7 understands this pattern:

```yaml linenums="1" hl_lines="8 9"
--8<-- "canary/canary-annotated.yaml"
```

```bash
kubectl apply -f canary/canary-annotated.yaml
```

### :white_check_mark: observe the ~20% split

```bash
# hit it 50 times, count which backend served (httpbin echoes Host/headers;
# we tag v2 via the VERSION env, visible at /get under "X-..." or use the pod)
for i in $(seq 1 50); do
  curl -s --resolve httpbin.example.com:8443:127.0.0.1 -k \
    https://httpbin.example.com:8443/get >/dev/null \
    && kubectl logs -n httpbin -l app=httpbin-v2 --tail=1 2>/dev/null >/dev/null
done
# simpler: watch request counts on each deployment's pods
kubectl logs -n httpbin deploy/httpbin    --tail=100 | wc -l
kubectl logs -n httpbin deploy/httpbin-v2 --tail=100 | wc -l   # ~1/5 of the v1 count
```

ramp the canary by editing one annotation — `canary-weight: "50"` — same as you would with nginx. no traefik yaml.

## path 2 — native TraefikService

the native equivalent: a weighted service + one route. clearer when you want the split in version control as a first-class object (and it composes with mirroring/failover).

```yaml linenums="1"
--8<-- "canary/canary-native.yaml"
```

```bash
# remove the annotated canary first so they don't both own the host
kubectl delete -f canary/canary-annotated.yaml
kubectl apply  -f canary/canary-native.yaml

kubectl port-forward -n traefik deploy/traefik 8080:8080 >/dev/null 2>&1 &
sleep 2
curl -s localhost:8080/api/http/services | jq '.[] | select(.name|test("httpbin-split")) | {name, weighted}'
```

### native unlocks (3.7)

- **mirroring** — shadow live traffic to v2, ignore its responses, compare behavior with zero user impact.
- **failover** — `TraefikService.failover` flips to a backup when the primary returns `500-504`. nginx couldn't express this without a mesh.

see `traefik-skills/traefik-resources.md` for both.

## next

cut nginx out entirely — carefully, preserving the IngressClass.
