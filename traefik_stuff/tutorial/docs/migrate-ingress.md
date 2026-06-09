# flip nginx ingresses to traefik

the `httpbin` Ingress is already served by both controllers. "migrating" it is just deciding **traefik owns it now** — and shifting traffic. no manifest rewrite.

## verify parity across the annotations

before cutover, confirm traefik honors each annotation the same as nginx. test both controllers for the same host:

```bash
NGINX_IP=127.0.0.1          # nginx on :80
TRAEFIK_PORT=8000           # traefik on :8000 (our k3d mapping)

echo "--- body-size limit (proxy-body-size: 10m) ---"
# 11MB upload should be rejected (413) by both
head -c 11000000 /dev/zero > /tmp/big
curl -s -o /dev/null -w "nginx:   %{http_code}\n" --resolve httpbin.example.com:80:$NGINX_IP \
  -X POST --data-binary @/tmp/big http://httpbin.example.com/post
curl -s -o /dev/null -w "traefik: %{http_code}\n" --resolve httpbin.example.com:$TRAEFIK_PORT:127.0.0.1 \
  -X POST --data-binary @/tmp/big http://httpbin.example.com:$TRAEFIK_PORT/post

echo "--- cors ---"
for tgt in "nginx:80:80" "traefik:$TRAEFIK_PORT:$TRAEFIK_PORT"; do
  name=${tgt%%:*}; port=${tgt##*:}
  printf "%-8s " "$name:"
  curl -is --resolve httpbin.example.com:$port:127.0.0.1 -H "Origin: https://ui.example.com" \
    http://httpbin.example.com:$port/get | grep -i access-control-allow-origin
done
```

both controllers behave identically because they read the same annotations. **that's the whole pitch.**

## the cutover decision

in a real cluster, "traefik owns it" = **dns points at traefik's LB IP** (and you flip `publishService`/default-class once nginx is gone). there is nothing to edit on the Ingress.

### local simulation of the dns cutover

locally we don't have dns, so simulate by pointing host :80 at traefik instead of nginx. in production this is a dns record change. the sequence is identical:

| step | production | this lab |
|------|------------|----------|
| 1. lower dns TTL | set record TTL=60s | n/a |
| 2. add traefik IP | dns round-robins nginx+traefik | curl both ports |
| 3. drop nginx IP | dns = traefik only | curl :8000 only |
| 4. soak 24-48h | watch metrics | watch `/api/overview` |

### watch traefik take the load

```bash
# request rate per router, live
curl -s localhost:8080/api/overview | jq '.http'
# access log: who served what
kubectl logs -n traefik deploy/traefik | jq -c 'select(.RequestHost=="httpbin.example.com")
  | {router:.RouterName, code:.DownstreamStatus, dur:.Duration}' | tail
```

## rollback (instant)

since you never edited the Ingress and nginx is still running, rollback is just "point dns back at nginx". locally, just keep using :80. there is no traefik artifact to delete and no manifest to revert.

## the key mental shift

> with envoy gateway, migration = rewrite every `Ingress` into `Gateway`+`HTTPRoute`.
> with traefik 3.7, migration = **dns cutover**. the `Ingress` objects are the migration artifact, unchanged.

## next

we tested over http. real services need https — let's wire cert-manager into traefik (your existing cert-manager `Certificate` objects barely change).
