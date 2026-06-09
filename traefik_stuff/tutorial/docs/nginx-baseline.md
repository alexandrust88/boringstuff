# the nginx baseline

before migrating, we need something to migrate. deploy an app behind an annotation-rich nginx `Ingress` — this represents your existing fleet.

## deploy the workload

```bash
kubectl apply -f nginx-baseline/httpbin.yaml
kubectl wait -n httpbin --for=condition=Available deploy/httpbin --timeout=120s
```

[httpbin](https://httpbin.org/) echoes request details back — perfect for seeing exactly what the proxy did to a request.

## deploy the nginx Ingress

```yaml linenums="1"
--8<-- "nginx-baseline/httpbin-ingress.yaml"
```

```bash
kubectl apply -f nginx-baseline/httpbin-ingress.yaml
```

note the annotations: `proxy-body-size`, `proxy-read-timeout`, `enable-cors`, `cors-allow-origin`, `whitelist-source-range`. **these are the things that usually make people fear an ingress migration.** with traefik 3.7 they translate automatically.

## :white_check_mark: test it through nginx

```bash
NGINX_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o go-template='{{ (index .status.loadBalancer.ingress 0).ip }}')
# on k3d the LB is usually 127.0.0.1
NGINX_IP=${NGINX_IP:-127.0.0.1}

curl -s --resolve httpbin.example.com:80:$NGINX_IP \
  http://httpbin.example.com/get | jq '{url, headers}'
```

you should get httpbin's JSON back. confirm cors is applied by nginx:

```bash
curl -is --resolve httpbin.example.com:80:$NGINX_IP \
  -H "Origin: https://ui.example.com" \
  http://httpbin.example.com/get | grep -i access-control-allow-origin
```

## inventory the annotations (the real first step of any migration)

```bash
kubectl get ingress -A -o json \
| jq -r '.items[].metadata.annotations // {} | keys[]' \
| grep '^nginx.ingress.kubernetes.io/' | sort | uniq -c | sort -rn
```

this is what you'd run against a production cluster to scope the migration. snippets/lua here would need manual handling — ours has none, so it's a clean automatic migration.

## next

we have a working nginx-served app with real annotations and **no intention of editing its Ingress**. now we bring traefik in beside nginx.
