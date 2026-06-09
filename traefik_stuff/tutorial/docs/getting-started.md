# getting started with traefik (compat mode)

install traefik 3.7.1 with the `kubernetesIngressNGINX` provider, **alongside** nginx. nothing about the `httpbin` Ingress changes.

## the values

```yaml linenums="1"
--8<-- "getting-started/traefik-compat-values.yaml"
```

two things to notice:

- `kubernetesIngressNGINX.enabled: true` — traefik reads the **same** nginx Ingress objects.
- `publishService.enabled: false` + `isDefaultClass: false` — traefik serves quietly, doesn't fight nginx over Ingress `.status`, doesn't steal the default class.

## install

```bash
helm install traefik traefik/traefik \
  -n traefik --create-namespace \
  --version 40.1.0 \
  -f getting-started/traefik-compat-values.yaml

kubectl wait -n traefik --for=condition=Available deploy/traefik --timeout=120s
```

## :white_check_mark: did traefik pick up the nginx Ingress?

```bash
# 1. provider logs mention ingress-nginx
kubectl logs -n traefik deploy/traefik | grep -iE 'ingress-nginx|kubernetesIngressNGINX' | tail

# 2. a router was built FROM the nginx Ingress
kubectl port-forward -n traefik deploy/traefik 8080:8080 >/dev/null 2>&1 &
sleep 2
curl -s localhost:8080/api/http/routers \
  | jq '.[] | select(.rule | test("httpbin.example.com")) | {name, rule, status, service}'
```

you should see a router matching `Host(\`httpbin.example.com\`)` with `status: "enabled"` — built automatically from the `Ingress` you never touched.

## :white_check_mark: serve the same app through traefik — without touching dns

nginx still owns the real path. test traefik on its own port:

```bash
# traefik's web entrypoint is mapped to host :8000 in our k3d setup
curl -s --resolve httpbin.example.com:8000:127.0.0.1 \
  http://httpbin.example.com:8000/get | jq '{url, headers}'
```

and confirm the **cors annotation translated automatically**:

```bash
curl -is --resolve httpbin.example.com:8000:127.0.0.1 \
  -H "Origin: https://ui.example.com" \
  http://httpbin.example.com:8000/get | grep -i access-control-allow-origin
```

same `Access-Control-Allow-Origin: https://ui.example.com` header — and you wrote zero traefik config to get it. the `enable-cors` / `cors-allow-origin` annotations on the nginx Ingress did the work.

## what just happened

```
httpbin Ingress (ingressClassName: nginx)  ← unchanged
   ├── ingress-nginx  → serves on :80/:443   (the real dns, untouched)
   └── traefik 3.7    → serves on :8000/:8443 (same routes, same cors)
```

both controllers, one manifest. you're now A/B testing traefik against production config with zero risk.

## next

translate the rest of the annotations (they already work) and then make traefik the real path.
