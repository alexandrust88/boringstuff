# https & cert-manager

add tls. the headline: traefik terminates tls from the **same nginx `Ingress`** using `spec.tls[].secretName`, and turns `ssl-redirect` into an http→https redirect — no traefik-specific yaml. and your cert-manager `Certificate` objects don't change.

## issue a cert (cert-manager)

```yaml linenums="1"
--8<-- "tls/selfsigned-issuer.yaml"
```

```bash
kubectl apply -f tls/selfsigned-issuer.yaml
kubectl wait -n httpbin --for=condition=Ready certificate/httpbin-tls --timeout=60s
kubectl get secret -n httpbin httpbin-tls     # kubernetes.io/tls
```

!!! note
    in production use a `letsencrypt-prod` ClusterIssuer with an http01/dns01 solver. when you cut over, flip the solver's `ingressClassName` from `nginx` to `traefik` (or keep `nginx` while both serve the class). nothing else changes.

## update the Ingress to use TLS — still an nginx Ingress

```yaml linenums="1" hl_lines="9 10 17 18 19"
--8<-- "tls/httpbin-ingress-https.yaml"
```

```bash
kubectl apply -f tls/httpbin-ingress-https.yaml
```

we added `ssl-redirect`, `force-ssl-redirect`, and a `tls:` block. it is **still `ingressClassName: nginx`** — both controllers honor it.

## :white_check_mark: test https through traefik

```bash
# traefik's websecure entrypoint is host :8443 in our k3d setup
curl -sk --resolve httpbin.example.com:8443:127.0.0.1 \
  https://httpbin.example.com:8443/get | jq '{url}'

# inspect the served cert
echo | openssl s_client -connect 127.0.0.1:8443 -servername httpbin.example.com 2>/dev/null \
  | openssl x509 -noout -subject -dates
```

## :white_check_mark: the ssl-redirect annotation became a redirect

```bash
# http should 301/308 to https — produced from the nginx ssl-redirect annotation
curl -is --resolve httpbin.example.com:8000:127.0.0.1 \
  http://httpbin.example.com:8000/get | head -1
```

## see it in the dashboard certificates view (3.7)

3.7 added a **Certificates** menu showing every cert, its domains, expiry, and which routers use it:

```bash
# port-forward the api and open the dashboard (lab only — never expose unauthenticated)
kubectl port-forward -n traefik deploy/traefik 8080:8080 >/dev/null 2>&1 &
open http://localhost:8080/dashboard/#/tls/certificates   # or browse the Certificates menu
```

## native equivalent (for later)

once you go native, the same thing is a `TLSOption` + `IngressRoute.tls.secretName`. you don't need it to migrate — it's there when you want cipher control and SNI policy. see `traefik-skills/traefik-security.md`.

## next

the annotations on this Ingress (cors, body-size, redirect) all translated for free. now let's translate the spicier ones — rate limiting and ip allowlisting — and see both the automatic path and the native `Middleware` path.
