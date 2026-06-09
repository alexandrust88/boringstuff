# decommission nginx

traefik serves everything. now remove ingress-nginx — **without deleting the `nginx` IngressClass**, which traefik still needs to match your unchanged Ingress objects.

## the trap

if nginx was helm-installed, `helm uninstall` deletes the `nginx` IngressClass. the moment that class is gone, traefik stops matching every `ingressClassName: nginx` Ingress → cluster-wide 404. **preserve the class first.**

## step 1 — pin the IngressClass so it survives

```bash
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --reuse-values \
  --set-json 'controller.ingressClassResource.annotations={"helm.sh/resource-policy":"keep"}'
```

gitops-managed instead? add a standalone `IngressClass` resource to your repo, owned separately from the nginx release, so it outlives the release deletion:

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
  annotations: { "helm.sh/resource-policy": keep }
spec:
  controller: k8s.io/ingress-nginx
```

## step 2 — remove the admission webhooks

once the controller is gone, its admission webhooks would block all Ingress writes. delete them first:

```bash
kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found
kubectl delete mutatingwebhookconfiguration   ingress-nginx-admission --ignore-not-found
```

## step 3 — uninstall nginx

```bash
helm uninstall ingress-nginx -n ingress-nginx
kubectl delete namespace ingress-nginx
```

## step 4 — confirm the class survived

```bash
kubectl get ingressclass nginx       # MUST still exist
```

if it's gone, recreate it from the yaml in step 1 immediately.

## step 5 — let traefik fully own the ingress surface

now that nginx is gone, flip the flags we held back during coexistence:

```bash
helm upgrade traefik traefik/traefik -n traefik --version 40.1.0 --reuse-values \
  --set providers.kubernetesIngressNGINX.publishService.enabled=true \
  --set ingressClass.isDefaultClass=true
```

- `publishService.enabled: true` — traefik now writes `Ingress .status` (external-dns etc. read it).
- `isDefaultClass: true` — new Ingresses with no class default to traefik.

## :white_check_mark: final verification

```bash
kubectl get ingressclass                                   # nginx (kept) + traefik
kubectl get ingress -A                                     # all still ingressClassName: nginx, unchanged
curl -sk --resolve httpbin.example.com:8443:127.0.0.1 \
  https://httpbin.example.com:8443/get | jq '{url}'        # served by traefik
kubectl port-forward -n traefik deploy/traefik 8080:8080 >/dev/null 2>&1 &
sleep 2; curl -s localhost:8080/api/overview | jq '.http.routers'   # routers present
```

your `Ingress` objects are byte-for-byte what they were on day one. nginx is gone. traefik serves them.

## next

what we learned.
