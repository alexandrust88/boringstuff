# rate limiting (deeper dive)

we already saw `limit-rps` translate automatically in the middlewares chapter. this chapter goes one level deeper on the differences between nginx and traefik rate limiting, because it's the annotation people most often get subtly wrong in migration.

## the annotations and what they become

| nginx annotation | traefik middleware | notes |
|------------------|--------------------|-------|
| `limit-rps: "5"` | `rateLimit{ average: 5, period: 1s }` | requests/second |
| `limit-rpm: "300"` | `rateLimit{ average: 300, period: 1m }` | requests/minute |
| `limit-connections: "10"` | `inFlightReq{ amount: 10 }` | concurrent in-flight, not a rate |
| `limit-burst-multiplier` | `rateLimit.burst` | burst allowance |
| `limit-whitelist` | `rateLimit` source exemption | IPs exempt from limiting |

## the gotcha: per-replica vs cluster-wide

nginx rate limits are **per nginx pod**. traefik's `rateLimit` is likewise **per traefik replica** by default. so with `replicas: 2` and `limit-rps: 5`, the effective cluster limit is ~10/s, not 5/s — *same as nginx behaved*. don't be surprised when the number looks doubled; it matched nginx all along.

if you need a true cluster-wide limit, that requires a distributed rate-limit store (traefik enterprise / a redis-backed plugin) — neither nginx OSS nor traefik OSS gives you cluster-wide limiting from the annotation alone. **don't promise stricter behavior than nginx delivered.**

## source criterion (whose requests get counted)

behind a load balancer, all requests look like they come from the LB unless you read `X-Forwarded-For`. set the ip strategy depth so the limit is per-real-client:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata: { name: ratelimit, namespace: httpbin }
spec:
  rateLimit:
    average: 5
    period: 1s
    burst: 10
    sourceCriterion:
      ipStrategy:
        depth: 1            # trust 1 hop of X-Forwarded-For (tune to your LB chain)
```

mismatch here is the usual cause of "the rate limit counts everyone as one client" after migration.

## :white_check_mark: prove it

```bash
kubectl apply -f middlewares/httpbin-native.yaml   # has the ratelimit middleware
for i in $(seq 1 30); do
  curl -s -o /dev/null -w "%{http_code} " -k \
    --resolve httpbin.example.com:8443:127.0.0.1 https://httpbin.example.com:8443/get
done; echo
# 200s up to the limit, then 429 Too Many Requests
```

## next

decommission nginx.
