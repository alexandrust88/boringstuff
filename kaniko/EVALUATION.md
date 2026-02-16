# unprivileged container image builds - evaluation

evaluation of kaniko, podman, and buildah for building container images without privileged access.

## summary

| criteria | kaniko | podman | buildah |
|----------|--------|--------|---------|
| rootless build | yes | yes | yes |
| daemonless | yes | yes | yes |
| runs in unprivileged pod | yes (native) | partial (needs uid mapping) | partial (needs uid mapping) |
| dockerfile support | full | full | full |
| oci compliant | yes | yes | yes |
| layer caching | yes (registry-based) | yes (local) | yes (local) |
| multi-stage builds | yes | yes | yes |
| build speed | medium | fast | fast |
| github actions support | manual (docker run) | pre-installed on runners | official red hat actions |
| k8s-native | designed for it | possible with config | possible with config |

## kaniko

### pros
- purpose-built for building images inside containers and kubernetes pods
- no docker daemon required - builds entirely in userspace
- runs natively in unprivileged pods without any special configuration
- no need for `/var/run/docker.sock` mount or privileged securitycontext
- registry-based caching works well in ci/cd and multi-node clusters
- google-maintained, widely adopted in kubernetes ecosystems

### cons
- slower than podman/buildah due to userspace filesystem snapshots
- must run as a container itself (not a standalone binary on the host)
- debugging build failures is harder - limited shell access during builds
- cache invalidation can be tricky with registry-based caching
- no support for `docker run` style commands - build-only tool

### kubernetes pod example (no privileges needed)
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kaniko-build
spec:
  containers:
    - name: kaniko
      image: gcr.io/kaniko-project/executor:latest
      args:
        - --dockerfile=Dockerfile
        - --context=git://github.com/org/repo.git
        - --destination=registry.example.com/app:latest
  restartPolicy: Never
  # no securitycontext escalation needed
```

## podman

### pros
- rootless by default - designed for unprivileged operation
- daemonless architecture - no background service to manage
- docker-compatible cli - drop-in replacement for most commands
- fast builds using local storage and overlay filesystem
- pre-installed on github actions ubuntu runners
- supports `podman play kube` for kubernetes manifest testing
- active community and red hat backing

### cons
- rootless mode in kubernetes pods requires uid mapping (`/etc/subuid`, `/etc/subgid`)
- needs `securityContext.runAsUser` and potentially `SYS_CHOWN` capability in k8s
- storage driver configuration needed for rootless in constrained environments
- not purpose-built for in-cluster builds like kaniko
- overlay filesystem may need fuse-overlayfs in restricted pods

### kubernetes pod example (needs some config)
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: podman-build
spec:
  containers:
    - name: podman
      image: quay.io/podman/stable:latest
      command: ["podman", "build", "-t", "app:latest", "."]
      securityContext:
        runAsUser: 1000
        # may need these depending on cluster policy:
        # capabilities:
        #   add: ["SYS_CHOWN", "SETUID", "SETGID"]
  restartPolicy: Never
```

## buildah

### pros
- rootless and daemonless - no docker daemon needed
- fine-grained control - can build images step-by-step without dockerfile
- scriptable - each build step is a separate command
- shares storage backend with podman (interoperable)
- official red hat github actions for easy ci/cd integration
- lightweight - smaller footprint than podman (build-only, no runtime)
- supports oci and docker image formats natively

### cons
- same rootless-in-k8s challenges as podman (uid mapping, storage drivers)
- less familiar cli compared to docker/podman for most teams
- scripted builds (without dockerfile) have a learning curve
- fewer online examples and community resources than kaniko or podman
- red hat ecosystem focus - less community diversity

### kubernetes pod example (needs some config)
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: buildah-build
spec:
  containers:
    - name: buildah
      image: quay.io/buildah/stable:latest
      command: ["buildah", "bud", "-t", "app:latest", "."]
      securityContext:
        runAsUser: 1000
        # same uid mapping requirements as podman
  restartPolicy: Never
```

## recommendation

### for kubernetes in-cluster builds (restricted pods): **kaniko**

kaniko is the clear winner when the primary requirement is building images inside kubernetes pods with restricted permissions. it was designed specifically for this use case and requires zero privilege escalation. no uid mapping, no capabilities, no fuse - it just works.

### for github actions ci/cd: **podman** or **buildah**

on github actions runners, podman and buildah are faster and simpler since they run natively on the host. podman is pre-installed on ubuntu runners, making it the zero-config option. buildah has polished red hat actions that abstract away complexity.

### for teams migrating from docker: **podman**

podman's docker-compatible cli makes it the easiest transition. same commands, rootless by default, no daemon to manage.

### overall recommendation

| use case | tool | reason |
|----------|------|--------|
| k8s pod builds (restricted) | kaniko | only tool that truly needs zero privileges in k8s |
| github actions ci/cd | podman | pre-installed, fast, docker-compatible |
| scripted/advanced builds | buildah | fine-grained step-by-step control |
| docker replacement | podman | drop-in cli compatibility |

**for the specific requirement of unprivileged pod builds, kaniko is the recommended choice.** for ci/cd pipelines on github actions, use podman for simplicity or buildah if you want the red hat actions ecosystem.
