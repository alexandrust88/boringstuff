# kaniko skill - unprivileged container builds in kubernetes

build container images inside kubernetes pods without privileged access. kaniko vs podman vs buildah comparison, restricted psa patterns, and ci/cd integration.

source: `./kaniko/`

---

## when to use

- building container images inside k8s pods (restricted psa namespaces)
- ci/cd pipelines that need to build images without docker daemon
- environments where privileged containers are prohibited
- air-gapped or pod-security-policy-enforced clusters

---

## tldr recommendation

| use case | tool | why |
|----------|------|-----|
| k8s pod builds (restricted psa) | **kaniko** | only tool that truly works with zero privileges |
| github actions ci/cd | **podman** | pre-installed on runners, docker-compatible cli |
| scripted/advanced builds | **buildah** | fine-grained step-by-step control |
| docker replacement | **podman** | drop-in cli compatibility |

**for kubernetes restricted pods: kaniko is the only working option** (with caveats - see below). podman and buildah fail in k8s pods not just for capabilities but also because they need host-level `newuidmap`/`newgidmap` setuid binaries, `/dev/fuse`, and user-namespace nesting - things k8s typically does not provide.

---

## comparison table

| criteria | kaniko | podman | buildah |
|----------|--------|--------|---------|
| rootless build | yes | yes | yes |
| daemonless | yes | yes | yes |
| **unprivileged k8s pod** | **yes (with caveats - see notes below)** | no (needs host setuid binaries + fuse) | no (needs host setuid binaries + fuse) |
| dockerfile support | full | full | full |
| oci compliant | yes | yes | yes |
| layer caching | yes (registry-based) | yes (local) | yes (local) |
| multi-stage builds | yes | yes | yes |
| build speed | medium | fast | fast |
| github actions support | manual (docker run) | pre-installed | official red hat actions |
| k8s-native | designed for it | possible with config | possible with config |

**notes on the "unprivileged k8s pod" row:**

- kaniko historically required **root-inside-container** to chroot/chmod during layer extraction. works under restricted psa only with specific image variants (`:debug`, `:slim`) and clusters **without** additional admission policies (kyverno, opa gatekeeper) enforcing `readOnlyRootFilesystem: true`.
- kaniko MUST write to `/` (root fs) to unpack image layers - `readOnlyRootFilesystem: true` is incompatible with kaniko builds.
- podman/buildah in-pod builds fail not just on capabilities but on missing host-level `newuidmap`/`newgidmap` setuid binaries, `/dev/fuse` device + `fuse-overlayfs` for rootless storage, and user-namespace nesting (disabled by default in most k8s runtimes).

---

## kaniko in kubernetes (restricted psa)

### full working pod spec

the key insight: kaniko can build under **restricted psa with zero privileges**. no uid mapping, no capabilities, no fuse-overlayfs. it just works (with caveats below).

> **caveat**: the distroless `gcr.io/kaniko-project/executor:latest` image runs as **root by default** inside the container and writes to `/kaniko` + `/` during builds. setting `runAsUser: 1000` at pod level conflicts unless you use specific variants:
> - `gcr.io/kaniko-project/executor:debug` - includes shell, easier to troubleshoot
> - `gcr.io/kaniko-project/executor:slim` - smaller footprint
>
> verify your cluster's psa admission actually accepts the build. some kyverno/opa policies enforce `readOnlyRootFilesystem: true` which kaniko **cannot** satisfy - it must write to root fs to unpack layers.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: build-kaniko
  namespace: build-eval
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault

  initContainers:
    # init container for git clone (kaniko executor can't clone under restricted)
    # using alpine/git (preferred for non-root; bitnami/git images have been deprecated)
    - name: fetch-source
      image: alpine/git:latest
      command: ["sh", "-c"]
      args:
        - |
          cd /source
          git clone https://github.com/org/repo.git .
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: false
        capabilities:
          drop: [ALL]
        seccompProfile:
          type: RuntimeDefault
      volumeMounts:
        - name: source
          mountPath: /source

  containers:
    - name: kaniko
      image: gcr.io/kaniko-project/executor:latest
      args:
        - --context=/source
        - --dockerfile=/source/Dockerfile
        - --destination=registry.example.com/app:latest
        # for local/test builds (no push):
        # - --no-push
        # - --tarPath=/output/image.tar
      securityContext:
        allowPrivilegeEscalation: false
        # readOnlyRootFilesystem MUST be false - kaniko unpacks image layers to /
        readOnlyRootFilesystem: false
        capabilities:
          drop: [ALL]
        seccompProfile:
          type: RuntimeDefault
      volumeMounts:
        - name: source
          mountPath: /source
          readOnly: true
        - name: output
          mountPath: /output
      resources:
        requests: { cpu: 200m, memory: 512Mi }
        limits:   { cpu: "1", memory: 1Gi }

  volumes:
    - name: source
      emptyDir: {}
    - name: output
      emptyDir: {}
```

### why this works with restricted psa

- `runAsNonRoot: true` + `runAsUser: 1000` ✓
- `allowPrivilegeEscalation: false` ✓
- `capabilities: drop: [ALL]` ✓
- `seccompProfile: RuntimeDefault` ✓ (set at both pod and container level - some admission controllers only check container-level)
- no capabilities need to be added
- no privileged securityContext
- no `/var/run/docker.sock` mount

**security caveat - readOnlyRootFilesystem:**

kaniko **needs a writable root fs**. it unpacks image layers into `/` during builds. the upstream restricted psa (k8s v1.25+) does **not** mandate `readOnlyRootFilesystem: true`, so kaniko works on a baseline restricted cluster. however, stricter admission controllers (kyverno, opa gatekeeper, pod-security-standards extensions) often enforce it. on such clusters, kaniko will fail with errors like `read-only file system` during layer extraction. you must either:

- add an exception for the kaniko namespace/pod in the policy
- use a different builder (none of which work under these constraints)
- reconsider whether your policy goals actually require read-only root for build pods

### kaniko args reference

```text
--context=<path|git|s3|gs>     # build context source
--context-sub-path=<path>      # subdirectory of context (monorepos)
--git branch=xxx,single-branch=true,recurse-submodules=true
                               # git context options (comma-separated kv)
--dockerfile=<path>            # dockerfile location
--destination=<registry/img>   # push destination (can repeat)
--no-push                      # build without pushing
--tarPath=<path>               # output tar file
--cache=true                   # enable registry-based cache
--cache-repo=<registry/cache>  # cache destination
--cache-ttl=24h                # cache expiry
--compressed-caching=false     # disable layer compression for speed
--single-snapshot              # take one snapshot at end (not per-step)
--ignore-path=<path>           # paths to exclude from snapshots (can repeat)
--registry-mirror=<host>       # mirror registry (can repeat)
--insecure                     # http registries
--insecure-pull                # http pulls
--skip-tls-verify              # skip cert verification
--target=<stage>               # multi-stage target
--build-arg=KEY=VALUE          # dockerfile ARG
--label=KEY=VALUE              # add label to image
--digest-file=/path            # write digest to file
--reproducible                 # deterministic builds
--snapshot-mode=redo           # alt snapshot (for some use cases)
--use-new-run                  # new run command implementation
--verbosity=info               # trace|debug|info|warn|error|fatal|panic
```

### kaniko image variants

| tag | use case | notes |
|-----|----------|-------|
| `gcr.io/kaniko-project/executor:latest` | production ci | distroless, no shell - cannot `kubectl exec` into it |
| `gcr.io/kaniko-project/executor:debug` | troubleshooting | includes busybox shell - `kubectl exec -it pod -- sh` works |
| `gcr.io/kaniko-project/executor:slim` | minimal footprint | strips optional features, no debug/help |

debug usage example:

```bash
# when a build fails mysteriously, swap to :debug and exec in
kubectl run kaniko-debug --image=gcr.io/kaniko-project/executor:debug \
  --restart=Never --rm -it --command -- sh
# inside the pod, inspect /kaniko, /workspace, env, etc.
```

### kaniko does NOT support buildkit features

kaniko is an **independent** builder, not a buildkit frontend. the following buildkit-only features will fail or be ignored:

- `RUN --mount=type=cache,...` (build cache mounts)
- `RUN --mount=type=secret,...` and `RUN --mount=type=ssh,...`
- heredocs: `RUN <<EOF ... EOF`
- alternative frontends (`# syntax=docker/dockerfile:1.4+`)
- `COPY --link` optimisation
- `RUN --network=none|host`

before migrating a complex buildkit-enabled dockerfile to kaniko, grep for `--mount=` / heredocs / `# syntax=` and refactor. a simple test build against the stock `:latest` image will surface incompatibilities quickly.

### kaniko with registry auth

```yaml
# create docker config secret
kubectl create secret generic regcred \
  --from-file=.dockerconfigjson=/path/to/.docker/config.json \
  --type=kubernetes.io/dockerconfigjson

# mount in kaniko pod
containers:
  - name: kaniko
    image: gcr.io/kaniko-project/executor:latest
    volumeMounts:
      - name: docker-config
        mountPath: /kaniko/.docker

volumes:
  - name: docker-config
    secret:
      secretName: regcred
      items:
        - key: .dockerconfigjson
          path: config.json
```

### kaniko with oci / harbor / ecr / gcr

```yaml
# gcr (workload identity)
serviceAccountName: kaniko-sa  # bound to gcp SA

# ecr (irsa)
serviceAccountName: kaniko-sa  # annotated with eks.amazonaws.com/role-arn

# harbor/generic (docker config secret)
# use regcred approach above
```

### kaniko caching strategy

```yaml
args:
  - --cache=true
  - --cache-repo=registry.example.com/cache/app
  - --cache-ttl=168h           # 7 days
  - --context=/source
  - --dockerfile=/source/Dockerfile
  - --destination=registry.example.com/app:$(GIT_SHA)
```

cache works by pushing intermediate layers to a separate repo. subsequent builds pull matching layers.

### kaniko cons to be aware of

- slower than podman/buildah due to userspace filesystem snapshots
- must run as a container itself (no standalone binary)
- harder to debug build failures - limited shell access during builds
- cache invalidation can be tricky with registry-based caching
- build-only tool - no `docker run` equivalent

---

## podman in kubernetes (will NOT work under restricted psa)

podman is included here to document **why it fails**. under restricted psa:

```yaml
# THIS POD WILL BE REJECTED
apiVersion: v1
kind: Pod
metadata:
  name: build-podman
  annotations:
    note: "this pod will be REJECTED by restricted psa - that is the point"
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: podman
      image: quay.io/podman/stable:latest
      command: ["podman", "build", ...]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
          # capabilities alone are NOT enough - see real root causes below
```

**real root causes why podman/buildah fail in restricted k8s pods** (adding capabilities does not fix these):

1. **no `newuidmap`/`newgidmap` setuid binaries on the host** - rootless podman needs these to map the container's uid range. k8s nodes rarely install them, and even when present, they must be **setuid** on the node filesystem, not inside the container image.
2. **no `/dev/fuse` device** - restricted psa disallows device mounts. without `/dev/fuse` + the `fuse-overlayfs` binary, podman cannot create overlay storage for rootless mode.
3. **user-namespace nesting disabled** - many k8s runtimes (containerd defaults, gke autopilot, eks bottlerocket) disable nested user namespaces. podman's rootless mode relies on creating a new user ns inside the pod's existing user ns.
4. **no `/etc/subuid` and `/etc/subgid` entries** - rootless mode requires sub-uid ranges configured for the runtime user on the host node, not in the image.

to make podman work in k8s you typically need: privileged container, host `/dev/fuse` mount, host setuid binaries, and relaxed psa - **or** a dedicated dind-style node pool. none of these are acceptable in hardened environments.

### podman on github actions (works great)

```yaml
# .github/workflows/build.yml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: build with podman
        run: |
          # podman is pre-installed on ubuntu runners
          podman build -t ghcr.io/${{ github.repository }}:${{ github.sha }} .

      - name: push
        run: |
          echo ${{ secrets.GITHUB_TOKEN }} | podman login ghcr.io -u ${{ github.actor }} --password-stdin
          podman push ghcr.io/${{ github.repository }}:${{ github.sha }}
```

---

## buildah

similar to podman - fails under restricted psa for the same reasons. works on github actions via official red hat actions.

```yaml
# .github/workflows/build.yml
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: buildah build
        uses: redhat-actions/buildah-build@v2
        with:
          image: my-app
          tags: ${{ github.sha }} latest
          containerfiles: ./Dockerfile

      - name: push to quay
        uses: redhat-actions/push-to-registry@v2
        with:
          image: my-app
          tags: ${{ github.sha }} latest
          registry: quay.io/org
          username: ${{ secrets.QUAY_USER }}
          password: ${{ secrets.QUAY_TOKEN }}
```

---

## kaniko with jobs / cronjobs

### one-shot build job

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: build-app
  namespace: ci
spec:
  ttlSecondsAfterFinished: 3600
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: kaniko-sa
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: fetch-source
          image: alpine/git:latest
          command: ["sh", "-c"]
          args:
            - |
              git clone --depth 1 --branch $BRANCH $REPO /source
          env:
            - { name: REPO,   value: "https://github.com/org/repo.git" }
            - { name: BRANCH, value: "main" }
          volumeMounts:
            - { name: source, mountPath: /source }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
            seccompProfile: { type: RuntimeDefault }
      containers:
        - name: kaniko
          image: gcr.io/kaniko-project/executor:latest
          args:
            - --context=/source
            - --dockerfile=/source/Dockerfile
            - --destination=registry.example.com/app:$(IMAGE_TAG)
            - --cache=true
            - --cache-repo=registry.example.com/cache/app
          env:
            - { name: IMAGE_TAG, value: "v1.2.3" }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
            seccompProfile: { type: RuntimeDefault }
          volumeMounts:
            - { name: source, mountPath: /source, readOnly: true }
            - { name: docker-config, mountPath: /kaniko/.docker }
      volumes:
        - { name: source, emptyDir: {} }
        - name: docker-config
          secret:
            secretName: regcred
            items:
              - { key: .dockerconfigjson, path: config.json }
```

### tekton / argo workflows integration

kaniko is the de-facto standard image builder for tekton pipelines and argo workflows. the same pod-level security settings apply - just wrap the invocation in the relevant crd.

**tekton TaskRun example** (uses the upstream `kaniko` catalog task):

```yaml
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: build-app-run
  namespace: ci
spec:
  taskRef:
    name: kaniko            # from tektoncd/catalog
    kind: ClusterTask
  serviceAccountName: kaniko-sa
  podTemplate:
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      fsGroup: 1000
      seccompProfile:
        type: RuntimeDefault
  params:
    - name: IMAGE
      value: registry.example.com/app:$(tasks.git-clone.results.commit)
    - name: DOCKERFILE
      value: ./Dockerfile
    - name: CONTEXT
      value: ./
    - name: EXTRA_ARGS
      value:
        - --cache=true
        - --cache-repo=registry.example.com/cache/app
        - --reproducible
  workspaces:
    - name: source
      persistentVolumeClaim:
        claimName: source-pvc
    - name: dockerconfig
      secret:
        secretName: regcred
```

for argo workflows, use a `script` or `container` template with the same kaniko image + args - the security context applies identically.

---

## running the built image (end-to-end validation)

after kaniko pushes an image, verify it runs under the same restricted psa. this catches non-root / port binding / writable-fs bugs in the dockerfile before deployment:

```yaml
---
# run the built image in a restricted pod
# usage: replace IMAGE with the tag kaniko just pushed
apiVersion: v1
kind: Pod
metadata:
  name: demo-app
  namespace: build-eval
  labels:
    app: demo-app
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: IMAGE
      ports:
        - containerPort: 8080
      securityContext:
        allowPrivilegeEscalation: false
        # note: the RUNTIME pod CAN use readOnlyRootFilesystem: true
        # (only the BUILD pod cannot - kaniko needs writable /)
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
        seccompProfile:
          type: RuntimeDefault
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          cpu: 100m
          memory: 64Mi
      livenessProbe:
        httpGet: { path: /health, port: 8080 }
        initialDelaySeconds: 2
        periodSeconds: 5
      readinessProbe:
        httpGet: { path: /health, port: 8080 }
        initialDelaySeconds: 1
        periodSeconds: 3
```

common failures that surface here (not at build time):

- image sets `USER root` - rejected by `runAsNonRoot: true`
- app binds to port < 1024 - fails without `NET_BIND_SERVICE` capability
- app writes to `/tmp`, `/var/log`, `/app/cache` - blocked by `readOnlyRootFilesystem: true` (mount emptyDirs for writable paths)

---

## troubleshooting

### "no space left on device"

kaniko extracts layers to `/` by default. increase emptyDir size:
```yaml
volumes:
  - name: source
    emptyDir:
      sizeLimit: 10Gi
```

or use `--snapshot-mode=redo` for less disk usage.

### "error pushing image: denied"

registry auth issue:
- verify secret: `kubectl get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d`
- verify mount: kaniko expects `/kaniko/.docker/config.json`
- check sa permissions (workload identity, irsa)

### "cache layer not found"

first build has no cache. expected. subsequent builds will use it if the cache repo is reachable.

### "error building image: operation not permitted"

usually means psa is preventing an operation. check:
- `seccompProfile: RuntimeDefault` is set
- `runAsNonRoot: true` is set
- `allowPrivilegeEscalation: false` is set
- no capabilities added

kaniko should work with all of these - if it doesn't, the image or args are wrong.

### slow builds

- enable caching: `--cache=true --cache-repo=...`
- use `--snapshot-mode=redo` for some workloads
- reduce build context size (use `.dockerignore`)
- consider multi-stage builds to reduce final image size

---

## best practices

### security

- always use `seccompProfile: RuntimeDefault`
- drop all capabilities
- use a dedicated service account with minimal rbac
- mount registry credentials via secret, not env vars
- set `automountServiceAccountToken: false` unless needed for workload identity

### performance

- enable registry-based caching with a long ttl
- use multi-stage dockerfiles to reduce final image size
- scope build context tightly (`.dockerignore`)
- parallel builds for monorepos with shared cache repo

### reliability

- set resource requests/limits
- use `ttlSecondsAfterFinished` on jobs to auto-cleanup
- set `backoffLimit` for retry on transient failures
- verify image digest: `--digest-file=/output/digest`

### supply chain

- pin kaniko image by digest: `gcr.io/kaniko-project/executor@sha256:...`
- use `--reproducible` for deterministic builds
- write digest to a file for downstream steps: `--digest-file=/output/digest`
- sign images with cosign **after** the push (separate step/container)
- generate sbom with syft and scan with grype or trivy

**cosign sign (keyless, oidc-based):**

```bash
# in a follow-up step that has access to the digest file
export COSIGN_EXPERIMENTAL=1
cosign sign --yes \
  registry.example.com/app@$(cat /output/digest)
```

**syft sbom generation:**

```bash
syft registry.example.com/app@$(cat /output/digest) \
  -o spdx-json=/output/sbom.spdx.json
```

**grype scan (fail build on high+):**

```bash
grype registry.example.com/app@$(cat /output/digest) \
  --fail-on high \
  --output table
```

**trivy scan (alternative, broader ecosystem):**

```bash
trivy image --exit-code 1 --severity HIGH,CRITICAL \
  registry.example.com/app@$(cat /output/digest)
```

these tools all run as plain containers with restricted psa (no privileges required) and fit naturally as post-build steps in a tekton pipeline or k8s job.
