# middlewares: annotations, then the native way

the things people dread migrating — rate limiting, connection caps, ip allowlists — translate automatically from annotations. then we show the **native `Middleware`** form, which is what you'd refactor hot paths into *after* migrating.

## path 1 — automatic (just annotations)

```yaml linenums="1" hl_lines="10 11 12"
--8<-- "middlewares/httpbin-ratelimit-annotated.yaml"
```

```bash
kubectl apply -f middlewares/httpbin-ratelimit-annotated.yaml
```

traefik built three middlewares from those annotations. confirm:

```bash
kubectl port-forward -n traefik deploy/traefik 8080:8080 >/dev/null 2>&1 &
sleep 2
curl -s localhost:8080/api/http/middlewares | jq '.[] | {name, type}' \
  | grep -iE 'ratelimit|inflight|ipallowlist|rate|ip' -A1
```

### :white_check_mark: see the rate limit fire

```bash
# limit-rps: 5 -> rapid requests should start returning 429
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{http_code} " --resolve httpbin.example.com:8443:127.0.0.1 \
    https://httpbin.example.com:8443/get -k
done; echo
# expect a mix of 200s then 429s once you exceed ~5/s
```

you wrote no traefik config. the `limit-rps` / `limit-connections` / `whitelist-source-range` annotations did it.

## path 2 — native Middleware (the refactor target)

same behavior, expressed as reusable, ordered, named objects. this is optional and route-by-route — do it *after* the cutover, only where you want the clarity/power.

```yaml linenums="1"
--8<-- "middlewares/httpbin-native.yaml"
```

```bash
# uses a different route name so it coexists with the annotated Ingress for comparison
kubectl apply -f middlewares/httpbin-native.yaml
curl -s localhost:8080/api/http/routers | jq '.[] | select(.name|test("httpbin-native")) | {rule, middlewares}'
```

### why bother going native?

| annotation | native Middleware buys you |
|------------|----------------------------|
| one bag of annotations per Ingress | **reusable** objects shared across many routes |
| order is implicit | **explicit, ordered** chain (auth → allowlist → ratelimit → headers) |
| `proxy-next-upstream` (errors only) | `retry.retryOn.statusCodes` — retry on **502/503/504** (3.7) |
| can't dedup | **service-level middlewares** (3.7) — set once on the Service |
| no failover | `TraefikService.failover` on error status (3.7) |

full catalog: `traefik-skills/traefik-resources.md`.

## ordering gotcha (the #1 middleware bug)

middlewares run **in list order**. `ip-allowlist` before `ratelimit` means blocked IPs never consume rate-limit budget. flip them and you rate-limit attackers before rejecting them. when something behaves oddly:

```bash
curl -s localhost:8080/api/http/routers | jq '.[] | select(.name|test("httpbin")) | {rule, middlewares}'
```

## next

canary deployments — `nginx.ingress.kubernetes.io/canary-weight` translates automatically; the native form is a `TraefikService`.
