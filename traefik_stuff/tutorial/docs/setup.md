# setup (k3d)

## provision a cluster

k3s bundles an old traefik v2 by default. we disable it so we install traefik **3.7.1** ourselves and don't get two traefiks fighting.

```bash linenums="1"
--8<-- "setup/make-local-k3d-cluster"
```

```bash
chmod +x ./setup/make-local-k3d-cluster
./setup/make-local-k3d-cluster
```

[About k3d](https://k3d.io/).

---

## install ingress-nginx (the thing we'll migrate OFF)

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  --set controller.ingressClassResource.default=true
```

wait for it:

```bash
kubectl wait -n ingress-nginx --for=condition=Available deploy/ingress-nginx-controller --timeout=120s
kubectl get ingressclass        # should show "nginx (default)"
```

---

## add the traefik chart repo (don't install yet)

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm search repo traefik/traefik --versions | head    # confirm 40.1.0+ -> appVersion v3.7.1
```

!!! note
    chart series is **40.x** (not `0.40.0`). `40.1.0`/`40.2.0` bundle appVersion `v3.7.1`. chart `40.0.0` bundled `v3.7.0`.

---

## (optional) cert-manager, for the https chapter

```bash
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace --set crds.enabled=true
```
