# wwwz

wwwz is an airgapped-friendly shipment of a wiz vulnerability report generator. a scheduled cronjob pulls findings from the wiz api, renders static html/json reports, and writes them to a pvc. a sidecar/secondary nginx deployment serves those reports behind an ingress (or gateway) with basic-auth. wiz credentials and the optional microsoft teams webhook are pulled from vault via external-secrets.

## architecture

```
                                                  +-------------------------+
                                                  |        vault            |
                                                  |  secret/wiz/api         |
                                                  |   - client_id           |
                                                  |   - client_secret       |
                                                  |   - teams_webhook_url   |
                                                  +------------+------------+
                                                               |
                                                               v
                                                  +-------------------------+
                                                  |   externalsecret        |
                                                  |   (eso + clustersecret  |
                                                  |    store)               |
                                                  +------------+------------+
                                                               |
                                                               v
  +-----------------+        +----------------+       +------------------+
  |   schedule      |  ----> |  cronjob       | --->  |   k8s secret     |
  |   (cron spec)   |        |  wiz-report    |       |   (env source)   |
  +-----------------+        +-------+--------+       +------------------+
                                     |
                                     | writes html / json
                                     v
                             +-------+--------+
                             |      pvc       |
                             |  reports-data  |
                             +-------+--------+
                                     |
                                     | reads (ro)
                                     v
  +-----------+   +---------+   +----+---------+   +----------------+
  |  client   |-->| ingress |-->|   nginx      |-->|   static html  |
  |  browser  |   | gateway |   |  (viewer)    |   |     reports    |
  +-----------+   +---------+   +------+-------+   +----------------+
                                       |
                                       | optional notify
                                       v
                                 +-----+------+
                                 |  teams     |
                                 |  webhook   |
                                 +------------+
```

## quick start - airgapped deploy

### in a connected environment

```bash
# build image using internal base image mirror
make build-airgapped REGISTRY=registry.example.com

# push to your connected-env registry (for testing)
make push REGISTRY=registry.example.com

# create the transfer bundle
make bundle
# produces dist/wwwz-bundle-0.1.0.tar.gz
```

transfer `dist/wwwz-bundle-0.1.0.tar.gz` to the airgapped environment.

### in the airgapped environment

```bash
# 1. extract bundle
tar xzf wwwz-bundle-0.1.0.tar.gz

# 2. load image and push to internal registry
docker load < wwwz-0.1.0.tar.gz
docker tag wwwz:0.1.0 registry.example.com/wwwz:0.1.0
docker push registry.example.com/wwwz:0.1.0

# 3. configure vault with wiz credentials
vault kv put secret/wiz/api \
  client_id=<your-wiz-client-id> \
  client_secret=<your-wiz-client-secret> \
  teams_webhook_url=<optional-teams-webhook>

# 4. install the chart
helm install wwwz ./wwwz-0.1.0.tgz \
  -n wwwz --create-namespace \
  -f your-values.yaml
```

## values you probably need to override

| value | purpose |
|-------|---------|
| `image.report.repository` | report image (default `registry.example.com/wwwz/report`) |
| `image.report.tag` | report image tag (default `0.1.0`) |
| `image.viewer.repository` | nginx image for viewer |
| `image.viewer.tag` | nginx image tag |
| `imagePullSecrets` | list of image pull secrets |
| `hostname` | public hostname for the viewer |
| `tlsSecretName` | tls cert secret for ingress |
| `ingress.enabled` | toggle ingress resource |
| `ingress.className` | ingress controller class (e.g. `nginx`, `traefik`) |
| `gateway.enabled` | toggle Gateway API HTTPRoute (alternative to ingress) |
| `gateway.parentRef.name` / `namespace` | target Gateway reference |
| `vaultPath` | vault kv path (default `secret/wiz/api`) |
| `vaultStore.name` | eso secret store name |
| `vaultStore.kind` | `ClusterSecretStore` or `SecretStore` |
| `teamsWebhook.enabled` | toggle teams webhook notifications |
| `schedule` | cron expression (default `0 2 * * *`) |
| `pvc.storageClass` | pvc storage class (empty = default) |
| `pvc.size` | pvc size (default `2Gi`) |
| `htpasswd` | htpasswd line for basic auth |
| `clusterFilter` | wiz cluster name substring filter (optional) |
| `maxClusters` | limit to first N clusters (0 = all) |

## operational commands

```bash
# watch cronjob runs
kubectl -n wwwz get cronjobs,jobs,pods

# logs from the latest report run
kubectl -n wwwz logs -l app.kubernetes.io/component=report --tail=200

# logs from the viewer
kubectl -n wwwz logs -l app.kubernetes.io/component=viewer --tail=200

# trigger a report run manually
kubectl -n wwwz create job --from=cronjob/wwwz-report manual-$(date +%s)

# exec into the viewer to inspect files
kubectl -n wwwz exec -it deploy/wwwz-viewer -- ls -l /usr/share/nginx/html

# verify externalsecret synced
kubectl -n wwwz get externalsecret,secret
```

## default credentials

the viewer is protected with basic auth. the shipped default is `admin` / `admin`. change it before exposing the ingress.

### regenerate htpasswd

```bash
# create a fresh file (first time)
htpasswd -cbB htpasswd admin <new-password>

# or just print the line to paste into values.yaml
htpasswd -nbB admin <new-password>
```

use the resulting line in `htpasswd` in your values file:

```yaml
htpasswd: "admin:$2y$05$..."
```

## teams webhook setup

the report job will post a summary to a microsoft teams channel if `TEAMS_WEBHOOK_URL` is set.

1. in the target teams channel, add an incoming webhook connector and copy the url.
2. store it in vault alongside the wiz credentials:

```bash
vault kv patch secret/wiz/api teams_webhook_url=https://outlook.office.com/webhook/...
```

3. eso will propagate it into the cronjob env via the synced secret. to disable notifications, leave the key empty or remove it and redeploy.

## local development

```bash
cp src/.env.example src/.env
# edit src/.env with your wiz credentials
make test-local
```
