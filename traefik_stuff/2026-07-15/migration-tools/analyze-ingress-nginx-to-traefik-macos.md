# Runbook: Analyze ingress-nginx to Traefik Migration from macOS

Last reviewed: 2026-07-15

> Version note (verified 2026-07-15): as of mid-2026 Traefik Proxy stable is **v3.7.6** and helm chart **v41.0.2** (chart v41.x bundles v3.7.x; v40.2.0 was the last on v3.7.1). The `kubernetesIngressNGINX` provider referenced by these analyzers is GA in v3.6.2+. Separately, **ingress-nginx was archived / went end-of-life on 2026-03-24** (no more releases or CVE patches; its planned successor InGate was also retired). The neutral upstream recommendation (Kubernetes SIG-Network / Gateway API project) is **migrate to Gateway API via `ingress2gateway`**; `traefik/ingress-nginx-migration` is the official analyzer only within Traefik's own materials. Factor the EOL urgency in: this is now a security-driven migration, not just a modernization.

> Install location: all binaries below install into a **persistent** `$TOOLS_DIR` (default `~/bin`), never `/tmp`, so they survive reboots and are not reinstalled each run. Downloads use per-tool temp files created with `mktemp` and are cleaned up immediately after the `install`/`mv`; nothing lasting is left in `/tmp`.

## Persistent tool directory

Pick one persistent location and reuse it every session. `~/bin` is the default; a repo-local `bin/` also works if you prefer to keep tools with this runbook.

```bash
export TOOLS_DIR="${TOOLS_DIR:-$HOME/bin}"
mkdir -p "$TOOLS_DIR"
```

Ensure it is on `PATH` (add to `~/.zshrc` so it persists across sessions):

```bash
grep -q 'TOOLS_DIR' "$HOME/.zshrc" 2>/dev/null || \
  printf '\nexport TOOLS_DIR="%s"\nexport PATH="$TOOLS_DIR:$PATH"\n' "$TOOLS_DIR" >> "$HOME/.zshrc"
source "$HOME/.zshrc"
```

Because the tools live in `$TOOLS_DIR` (not `/tmp`), you install once and skip sections 2-7 on subsequent runs. Re-run a section only to upgrade a tool.

## Purpose

Install and run the available ingress-nginx migration analysis CLIs from a Mac against multiple Kubernetes clusters. The workflow is read-only and produces per-cluster JSON, Markdown, HTML, YAML, and warning reports.

The recommended tools are:

1. `ingress-nginx-migration`: official Traefik compatibility analyzer.
2. `ing-switch`: richer community analyzer from Saiyam Pathak, including JSON and HTML reports.
3. `ingress2gateway`: official Kubernetes SIG Network converter and untranslated-feature reporter.

Optional tools:

4. `nginx-traefik-converter`: experimental Traefik CRD-native converter.
5. `ingress-migration-analyzer`: small risk-classification scanner with lower annotation coverage.
6. `shiftscope`: local-manifest semantic risk analyzer; it does not directly scan the active cluster.

Do not use any tool's `apply` operation during the assessment phase.

## Does an exported `KUBECONFIG` work?

Mostly yes, but context selection differs.

| Tool | Reads `KUBECONFIG` | Multiple files in `KUBECONFIG` | Context selection | All namespaces |
| --- | --- | --- | --- | --- |
| `ingress-nginx-migration` | Yes | Uses the merged configuration | Uses only the kubeconfig's current context; no `--context` flag | Default |
| `ing-switch` | Yes | Uses the merged configuration | `--context CONTEXT` | Default |
| `ingress2gateway` | Yes (`--kubeconfig`) | Prefer one flattened kubeconfig file | Supports `--kubeconfig` but **no documented `--context` flag** — use a per-context flattened kubeconfig | Requires `-A` |
| `nginx-traefik-converter` | Yes | Uses kubeconfig | `-c CONTEXT` | `-a` |
| `ingress-migration-analyzer` | Yes | Uses kubeconfig | Supports a context option | Scanner-dependent |
| `shiftscope` | No live-cluster scan | Not applicable | Not applicable | Analyze exported YAML or Git manifests |
| Ingress Traefik Converter | Yes | Uses kubeconfig (paginated access) | `-c <context>` directly | Converter-dependent |
| `kube-migrate` | Only demonstrates mounting `~/.kube` | Unverified | **Unverified — do not use in fleet automation until custom kubeconfig/context handling is confirmed** | Unverified |
| `gwctl` | Yes (kubectl-style) | Uses the merged configuration | kubectl-style `--context` | `-A` |

On macOS, `KUBECONFIG` can contain multiple colon-separated paths:

```bash
export KUBECONFIG="$HOME/.kube/config:$HOME/.kube/fleet-config"
```

Kubernetes merges them. If the same context, cluster, or user name exists in multiple files, the first file defining that key wins. Check the effective configuration before scanning:

```bash
kubectl config get-contexts
kubectl config current-context
kubectl cluster-info
kubectl auth can-i list ingresses.networking.k8s.io --all-namespaces
kubectl auth can-i list ingressclasses.networking.k8s.io
```

For a single cluster kubeconfig, exporting `KUBECONFIG` is sufficient:

```bash
export KUBECONFIG="$HOME/.kube/cluster-a.yaml"
```

For a fleet kubeconfig containing multiple contexts, explicitly pass `--context` where supported. For tools without a context flag, create a temporary, flattened kubeconfig for the selected context. Do not repeatedly run `kubectl config use-context` in parallel because it mutates shared state.

## Required permissions

The official Traefik analyzer is read-only. The kubeconfig identity needs at least:

- `get`, `list`, and `watch` on `networking.k8s.io/ingresses`.
- `get`, `list`, and `watch` on `networking.k8s.io/ingressclasses`.

Verify:

```bash
kubectl auth can-i get ingresses.networking.k8s.io --all-namespaces
kubectl auth can-i list ingresses.networking.k8s.io --all-namespaces
kubectl auth can-i watch ingresses.networking.k8s.io --all-namespaces
kubectl auth can-i list ingressclasses.networking.k8s.io
```

The scanners may also inspect Services, Secrets, ConfigMaps, CRDs, Deployments, or controller Pods. If a tool reports RBAC errors, add only the missing read permissions. Do not grant mutation permissions for an assessment.

## 1. Install prerequisites on macOS

Install Homebrew first if it is not already available, then:

```bash
brew update
brew install kubectl jq yq go pipx python@3.12
pipx ensurepath
```

Open a new terminal or reload the shell:

```bash
exec zsh
```

The persistent binary directory `$TOOLS_DIR` and its `PATH` entry were set up in the "Persistent tool directory" section above. Confirm it is active before installing:

```bash
echo "TOOLS_DIR=${TOOLS_DIR:?run the Persistent tool directory section first}"
case ":$PATH:" in *":$TOOLS_DIR:"*) echo "on PATH";; *) echo "NOT on PATH — re-source ~/.zshrc";; esac
```

## 2. Install the official Traefik analyzer

Repository: <https://github.com/traefik/ingress-nginx-migration> (latest release: `v1.0.0`, 2025-12-08 — early, single-release; treat its flags as needing a `--help` check, see below).

Skip if `command -v ingress-nginx-migration` already resolves inside `$TOOLS_DIR`.

Download and inspect the installer before executing it:

```bash
installer="$(mktemp -t install-ingress-nginx-migration.XXXXXX.sh)"
curl -fsSL \
  https://raw.githubusercontent.com/traefik/ingress-nginx-migration/main/scripts/install.sh \
  -o "$installer"

less "$installer"
# the installer's --no-sudo mode installs into a user bin dir; point it at $TOOLS_DIR
INSTALL_DIR="$TOOLS_DIR" bash "$installer" --no-sudo
rm -f "$installer"
```

If the installer ignores `INSTALL_DIR` and drops the binary elsewhere (e.g. `~/.local/bin`), move it into `$TOOLS_DIR` so all tools live in one persistent place:

```bash
command -v ingress-nginx-migration | grep -q "$TOOLS_DIR" || \
  mv "$(command -v ingress-nginx-migration)" "$TOOLS_DIR/"
```

Verify:

```bash
command -v ingress-nginx-migration
ingress-nginx-migration version
ingress-nginx-migration --help   # <-- confirm the actual flag names used in sections 10-11
```

## 3. Install `ing-switch`

Repository: <https://github.com/saiyam1814/ing-switch>

Skip if `command -v ing-switch` already resolves inside `$TOOLS_DIR`.

Select the correct binary automatically. This block is written so it is safe to paste into an interactive shell — it uses `ING_SWITCH_ASSET=""` as a guard instead of `exit 1` (a bare `exit` would close your terminal tab):

```bash
ING_SWITCH_ASSET=""
case "$(uname -m)" in
  arm64)  ING_SWITCH_ASSET="ing-switch-darwin-arm64" ;;
  x86_64) ING_SWITCH_ASSET="ing-switch-darwin-amd64" ;;
  *)      echo "Unsupported architecture: $(uname -m)" >&2 ;;
esac

if [ -n "$ING_SWITCH_ASSET" ]; then
  tmp="$(mktemp -t ing-switch.XXXXXX)"
  curl -fL \
    "https://github.com/saiyam1814/ing-switch/releases/latest/download/${ING_SWITCH_ASSET}" \
    -o "$tmp"
  chmod 0755 "$tmp"
  mv "$tmp" "$TOOLS_DIR/ing-switch"
fi
```

Verify:

```bash
command -v ing-switch
ing-switch --help   # <-- confirm the analyze/report/doctor subcommands and --ci exit codes below
```

## 4. Install `ingress2gateway`

Repository: <https://github.com/kubernetes-sigs/ingress2gateway> (latest `v1.2.0`, 2026-07-07; a Traefik provider was added in `v1.1.0`. This is the single migration tool endorsed by both the ingress-nginx retirement notice and the Gateway API project.)

**Pin `v1.2.0`, not `v1.0.0`** — v1.1.0/v1.2.0 add the Traefik provider, regex fixes, SSL passthrough, redirects, and broader annotation support. If you installed an older build, upgrade.

Homebrew may not carry this formula. If `brew install` fails, use `go install` (Go was installed in section 1) with the pinned tag:

```bash
brew install ingress2gateway 2>/dev/null || \
  GOBIN="$TOOLS_DIR" go install github.com/kubernetes-sigs/ingress2gateway@v1.2.0
```

Verify (must report v1.2.0 or newer):

```bash
command -v ingress2gateway
ingress2gateway version 2>/dev/null || ingress2gateway --help
```

## 5. Optional: install `nginx-traefik-converter`

Repository: <https://github.com/nikhilsbhat/nginx-traefik-converter>

This project is young. Use it to generate review material, not to mutate fleet clusters.

```bash
brew tap nikhilsbhat/stable \
  https://github.com/nikhilsbhat/homebrew-stable.git

brew install nikhilsbhat/stable/nginx-traefik-converter
```

If the Homebrew formula is unavailable, build from source:

```bash
git clone https://github.com/nikhilsbhat/nginx-traefik-converter.git
cd nginx-traefik-converter
make local.build
```

Verify after installation:

```bash
command -v nginx-traefik-converter
nginx-traefik-converter --help
```

## 6. Optional: install `ingress-migration-analyzer`

Repository: <https://github.com/ibexmonj/ingress-migration-analyzer>

This scanner has substantially lower annotation coverage than the official analyzer and `ing-switch`. Its published one-line binary example is Linux-specific, so on macOS build it from source rather than downloading the Linux binary.

```bash
git clone https://github.com/ibexmonj/ingress-migration-analyzer.git
cd ingress-migration-analyzer
go build -o "$TOOLS_DIR/ingress-migration-analyzer" .
```

If the repository has moved its `main` package, inspect the available command directories and build the matching one:

```bash
find ./cmd -maxdepth 2 -name main.go -print
```

Verify:

```bash
ingress-migration-analyzer --help
```

Do not block the assessment if this optional tool does not build; it is not part of the recommended baseline.

## 7. Optional: install ShiftScope

Repository: <https://github.com/thc1006/shiftscope>

ShiftScope requires Python 3.12 or newer and analyzes local manifest files rather than the current cluster directly.

```bash
pipx install \
  --python "$(brew --prefix python@3.12)/bin/python3.12" \
  'shiftscope[cli]'
```

Verify:

```bash
shiftscope list
shiftscope --help
```

## 8. Validate the selected cluster

```bash
echo "KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}"
kubectl config current-context
kubectl cluster-info
kubectl get ingressclass
kubectl get ingress -A --no-headers | wc -l
```

Confirm that the relevant IngressClass/controller values are actually `nginx` and `k8s.io/ingress-nginx`:

```bash
kubectl get ingressclass -o custom-columns=NAME:.metadata.name,CONTROLLER:.spec.controller
```

If your values differ, replace them in the commands below.

## 9. Create the report workspace

```bash
export REPORT_ROOT="$PWD/traefik-migration-reports"

mkdir -p \
  "$REPORT_ROOT/official/json" \
  "$REPORT_ROOT/official/markdown" \
  "$REPORT_ROOT/ing-switch/json" \
  "$REPORT_ROOT/ing-switch/html" \
  "$REPORT_ROOT/ingress2gateway/yaml" \
  "$REPORT_ROOT/ingress2gateway/warnings" \
  "$REPORT_ROOT/logs" \
  "$REPORT_ROOT/tmp-kubeconfigs"
```

Protect the report directory because resource names, namespaces, hosts, and annotation values may be sensitive:

```bash
chmod 0700 "$REPORT_ROOT"
```

## 10. Run against one cluster

### Official Traefik JSON report

```bash
ingress-nginx-migration \
  --ingress-class nginx \
  --controller-class k8s.io/ingress-nginx \
  --format json \
  --output-file "$REPORT_ROOT/official/json/current.json"
```

Gate on full compatibility:

```bash
jq -e '.unsupportedIngressCount == 0' \
  "$REPORT_ROOT/official/json/current.json"
```

The official CLI exits non-zero only for execution errors. It does not fail merely because incompatible Ingresses were found, so the `jq` gate is required.

Caveat: `.unsupportedIngressCount` is the assumed field name — confirm it against the tool's actual JSON before trusting the gate. If the key is misspelled or nested, `jq -e` evaluates `null == 0`, which is `false`, and the gate reports "not compatible" even on a clean cluster (a false alarm). Verify the schema once:

```bash
jq 'keys' "$REPORT_ROOT/official/json/current.json"
```

### Official compact Markdown summary

```bash
ingress-nginx-migration \
  --ingress-class nginx \
  --controller-class k8s.io/ingress-nginx \
  --format markdown \
  --summary \
  --output-file "$REPORT_ROOT/official/markdown/current-summary.md"
```

### `ing-switch` JSON analysis

```bash
ing-switch \
  analyze \
  --target traefik \
  --output json \
  > "$REPORT_ROOT/ing-switch/json/current.json"
```

### `ing-switch` HTML report

```bash
ing-switch \
  report \
  --target traefik \
  --output "$REPORT_ROOT/ing-switch/html/current.html"
```

Open it:

```bash
open "$REPORT_ROOT/ing-switch/html/current.html"
```

### `ing-switch` readiness check

```bash
ing-switch doctor
```

### Gateway API conversion preview

This command only writes generated YAML and warnings locally:

```bash
ingress2gateway print \
  --providers ingress-nginx \
  --ingress-nginx-ingress-class nginx \
  --all-namespaces \
  --output yaml \
  > "$REPORT_ROOT/ingress2gateway/yaml/current.yaml" \
  2> "$REPORT_ROOT/ingress2gateway/warnings/current.log"
```

Review untranslated features:

```bash
less "$REPORT_ROOT/ingress2gateway/warnings/current.log"
```

## 11. Fleet run across every kubeconfig context

Save the following as `scan-traefik-fleet.sh`:

```bash
#!/usr/bin/env bash

set -uo pipefail

KUBECONFIG_SOURCE="${KUBECONFIG:-$HOME/.kube/config}"
REPORT_ROOT="${REPORT_ROOT:-$PWD/traefik-migration-reports}"

mkdir -p \
  "$REPORT_ROOT/official/json" \
  "$REPORT_ROOT/official/markdown" \
  "$REPORT_ROOT/ing-switch/json" \
  "$REPORT_ROOT/ing-switch/html" \
  "$REPORT_ROOT/ingress2gateway/yaml" \
  "$REPORT_ROOT/ingress2gateway/warnings" \
  "$REPORT_ROOT/logs" \
  "$REPORT_ROOT/tmp-kubeconfigs"

chmod 0700 "$REPORT_ROOT"

sanitize_name() {
  printf '%s' "$1" | tr '/:@ ' '____' | tr -cd '[:alnum:]_.-'
}

kubectl config get-contexts -o name | while IFS= read -r context; do
  [ -n "$context" ] || continue

  safe_context="$(sanitize_name "$context")"
  # non-ASCII or all-punctuation context names can sanitize to empty and then collide
  # (all become ".yaml"); fall back to a stable hash of the original name.
  [ -n "$safe_context" ] || safe_context="ctx-$(printf '%s' "$context" | shasum | cut -c1-8)"
  isolated_kubeconfig="$REPORT_ROOT/tmp-kubeconfigs/${safe_context}.yaml"

  echo "[$(date -u +%FT%TZ)] scanning $context"

  if ! kubectl \
    --context "$context" \
    config view \
    --raw \
    --flatten \
    --minify \
    > "$isolated_kubeconfig"; then
    echo "Unable to create kubeconfig for $context" \
      > "$REPORT_ROOT/logs/${safe_context}.kubeconfig-error.log"
    continue
  fi

  chmod 0600 "$isolated_kubeconfig"

  if ! KUBECONFIG="$isolated_kubeconfig" \
    kubectl cluster-info \
    > "$REPORT_ROOT/logs/${safe_context}.cluster-info.log" 2>&1; then
    echo "Cluster access failed: $context" >&2
    continue
  fi

  KUBECONFIG="$isolated_kubeconfig" \
  ingress-nginx-migration \
    --ingress-class nginx \
    --controller-class k8s.io/ingress-nginx \
    --format json \
    --output-file "$REPORT_ROOT/official/json/${safe_context}.json" \
    > /dev/null \
    2> "$REPORT_ROOT/logs/${safe_context}.official-json.log" || true

  KUBECONFIG="$isolated_kubeconfig" \
  ingress-nginx-migration \
    --ingress-class nginx \
    --controller-class k8s.io/ingress-nginx \
    --format markdown \
    --summary \
    --output-file "$REPORT_ROOT/official/markdown/${safe_context}.md" \
    > /dev/null \
    2> "$REPORT_ROOT/logs/${safe_context}.official-markdown.log" || true

  ing-switch \
    --kubeconfig "$KUBECONFIG_SOURCE" \
    --context "$context" \
    analyze \
    --target traefik \
    --output json \
    > "$REPORT_ROOT/ing-switch/json/${safe_context}.json" \
    2> "$REPORT_ROOT/logs/${safe_context}.ing-switch.log" || true

  ing-switch \
    --kubeconfig "$KUBECONFIG_SOURCE" \
    --context "$context" \
    report \
    --target traefik \
    --output "$REPORT_ROOT/ing-switch/html/${safe_context}.html" \
    >> "$REPORT_ROOT/logs/${safe_context}.ing-switch.log" \
    2>&1 || true

  KUBECONFIG="$isolated_kubeconfig" \
  ingress2gateway print \
    --providers ingress-nginx \
    --ingress-nginx-ingress-class nginx \
    --all-namespaces \
    --output yaml \
    > "$REPORT_ROOT/ingress2gateway/yaml/${safe_context}.yaml" \
    2> "$REPORT_ROOT/ingress2gateway/warnings/${safe_context}.log" || true
done

echo "Reports written under: $REPORT_ROOT"
```

Run it sequentially first:

```bash
chmod 0755 scan-traefik-fleet.sh
./scan-traefik-fleet.sh
```

Sequential execution is intentional for the first fleet pass. It avoids simultaneously refreshing authentication plugins and overloading many API servers. After measuring runtime and throttling, concurrency can be introduced with a small fixed worker count such as 5.

## 12. Use `ing-switch --ci` correctly

`ing-switch` documents these exit codes:

- `0`: fully compatible.
- `1`: unsupported annotations found.
- `2`: partial mappings or workarounds required.

Example:

```bash
set +e

ing-switch \
  --context cluster-a \
  analyze \
  --target traefik \
  --output json \
  --ci \
  > cluster-a.json

rc=$?
set -e

case "$rc" in
  0) echo "Compatible" ;;
  1) echo "Unsupported annotations found" ;;
  2) echo "Partial mappings found" ;;
  *) echo "Tool execution failed with code $rc" ;;
esac
```

Do not execute it under `set -e` without explicitly handling exit codes 1 and 2.

## 13. Run the optional tools

### Traefik CRD-native conversion preview

```bash
nginx-traefik-converter convert -c cluster-a -a
```

Do not apply its generated resources automatically.

### ShiftScope local analysis

Export a representative Ingress manifest:

```bash
kubectl \
  --context cluster-a \
  -n application-namespace \
  get ingress application-ingress \
  -o yaml \
  > application-ingress.yaml
```

Analyze it:

```bash
shiftscope analyze \
  gateway-api \
  application-ingress.yaml \
  --output markdown \
  > application-ingress-shiftscope.md
```

ShiftScope is a complementary semantic check, not a replacement for the fleet scanners.

## 14. What the CLIs do not fully analyze

Run a separate inventory for:

- ingress-nginx controller ConfigMaps and customized keys.
- Controller command-line arguments and Helm values.
- `tcp-services` and `udp-services` ConfigMaps.
- Custom NGINX templates.
- `main-snippet`, `http-snippet`, `server-snippet`, `location-snippet`, `stream-snippet`, and `configuration-snippet` contents.
- ModSecurity and OWASP CRS configuration.
- Custom Lua or NGINX modules.
- Service annotations controlling Azure, AWS, GCP, or on-premises load balancers.
- PROXY protocol and forwarded-header trust configuration.
- Default backend behavior.
- Admission webhooks.
- ExternalDNS dependencies on `Ingress.status.loadBalancer`.
- TLS secret availability and cross-namespace expectations.

Basic inventory commands:

```bash
kubectl -n ingress-nginx get configmap -o yaml \
  > "$REPORT_ROOT/ingress-nginx-configmaps.yaml"

kubectl -n ingress-nginx get deployment,daemonset -o yaml \
  > "$REPORT_ROOT/ingress-nginx-controller-workloads.yaml"

kubectl get ingress -A -o json |
  jq '[
    .items[] |
    select(
      any(
        (.metadata.annotations // {} | keys[]) ;
        test("snippet")
      )
    ) |
    {
      namespace: .metadata.namespace,
      name: .metadata.name,
      annotations: .metadata.annotations
    }
  ]' \
  > "$REPORT_ROOT/snippet-ingresses.json"
```

## 15. Recommended interpretation

The recommended end-to-end pipeline (assessment → conversion → post-deploy validation → capacity):

1. **Official Traefik analyzer** (`ingress-nginx-migration`) — the authoritative compatibility baseline (JSON is the machine-readable gate).
2. **`ing-switch`** JSON and HTML — wider annotation classification (119+ annotations) and per-Ingress impact rating; also generates Traefik / Gateway API resources.
3. **`ingress2gateway` v1.2.0** — the standards-based Gateway API conversion path; reports parsed, unsupported, and unknown annotations. (Pin **v1.2.0**, not v1.0.0 — see section 4.)
4. **`gwctl analyze`** *after* the converted resources are deployed — identifies routes the controller actually **rejected or left unresolved** (`Accepted` / `ResolvedRefs` status). A scanner saying "supported" is not the same as the controller accepting it.
5. **`gateway-api-bench` + real traffic replay** — per-cluster capacity and behavior testing. Build your own per-cluster route distribution; the published 5,000-route scenario does not prove large-fleet capacity.

Steps 1-3 are read-only assessment (sections 10-11). Step 4 runs against a cluster where you have already applied the generated Gateway API resources — do that in staging first. Step 5 is capacity work, separate from correctness.

Optional converters (`nginx-traefik-converter`, "Ingress Traefik Converter", `kube-migrate`) provide reviewable examples only — never auto-apply their output. Runtime testing must validate behavior even when a scanner says an annotation is supported: important behavioral differences may remain around external authentication, session affinity, CORS, regex and path normalization, trailing slashes, buffering, retry selection, rate limiting, backend protocols, TLS, and NGINX snippets.

## 16. Cleanup

The isolated kubeconfigs contain credentials or authentication configuration. Remove them after completing the scan:

```bash
rm -rf "$REPORT_ROOT/tmp-kubeconfigs"
```

Keep the reports in a protected location and do not commit them to Git until they have been reviewed for hostnames, namespaces, annotation values, authentication URLs, and other sensitive metadata.

## 17. Other tooling and the upstream direction (surveyed 2026-07-15)

Beyond the eight tools above, a GitHub/ecosystem survey turned up the following. Most of the ecosystem's momentum is toward **Gateway API**, not toward any single Traefik-specific converter — and that matters because ingress-nginx is already EOL.

### Tools worth knowing (not covered above)

Verdicts use three tiers: **Add** (fold into the pipeline now), **Watch** (promising but too immature for fleet automation), **Situational** (only if the target controller changes).

| tool | repo | targets | type | verdict / maturity |
| --- | --- | --- | --- | --- |
| `gwctl` v0.2.0 | <https://github.com/kubernetes-sigs/gwctl> | Gateway API (any implementation, incl. Traefik) | **post-deployment analyzer** — inspects generated Gateway API resources, relationships, policies, and `Accepted`/`ResolvedRefs` status | **Add.** Run *after* conversion+deploy to see what the controller actually accepted vs. rejected. Now `brew install gwctl`. |
| `gateway-api-bench` | <https://github.com/kubernetes-sigs/gateway-api-bench> (verify exact org) | Gateway API controllers | **benchmark harness** — route churn, resource usage, config-propagation latency | **Add to capacity testing.** Published scenario is 5,000 routes; build your own per-cluster route distribution — it does **not** prove large-fleet (e.g. 600k-route) capacity. |
| Ingress Traefik Converter | (Traefik-native IngressRoute/Middleware/TLSOption converter; verify repo) | **Traefik CRDs** (IngressRoute/Middleware/TLSOption) | converter, paginated k8s access, `-c <context>` support | **Situational (sandbox).** Useful for complex CRD-native conversions; tiny, inconsistent release/Homebrew docs. |
| `kube-migrate` | (new CLI/UI; verify repo) | Traefik manifests + complexity scoring | scanner + converter: 50+ annotations, complexity score, dependency graph, Markdown reports | **Watch only.** ~1 star, source/Docker install, no fleet-scale evidence, no dependable JSON aggregation yet. Only demonstrates mounting `~/.kube` — do **not** put in fleet automation until custom kubeconfig/context handling is verified. |
| `ingress2eg` | <https://github.com/kkk777-7/ingress2eg> | Gateway API + **Envoy Gateway** CRDs | converter (reads cluster or files) | **Situational.** ~18 stars, `v0.3.1` (2026-01), self-labeled POC/temporary. Only if evaluating Envoy Gateway instead of Traefik. |
| ShiftScope | <https://github.com/thc1006/shiftscope> | Gateway API / semantic risk | semantic migration-risk framework, structured findings | **Watch only.** Interesting design, early project, limited rule set. (Install steps in section 7 if you want to try it on exported manifests.) |
| HAProxy "Ingress NGINX Migration Assistant" | vendor page: <https://www.haproxy.com/ingress-nginx-migration-assistant> | HAProxy ingress controller | vendor toolkit + "shift and shield" coexistence pattern | **Situational.** **No confirmed standalone open-source repo**; the controller (`haproxytech/kubernetes-ingress`) is OSS with config-conversion flags. Only if considering HAProxy. |
| kgateway migration path | <https://github.com/kgateway-dev/kgateway>, guide <https://kgateway.dev/blog/ingress-nginx-migration-gateway-api/> | Gateway API (Envoy/kgateway) | ships **no bespoke converter** — reuses `ingress2gateway` + remaps annotations to kgateway policy CRDs | **Situational.** Established CNCF Sandbox project; the "tool" is really ingress2gateway plus policy docs. |

> Repo-URL caveat: `gateway-api-bench`, "Ingress Traefik Converter", and `kube-migrate` came from a survey and their exact repo paths/Homebrew formulae are not yet verified here — confirm the URL and install method before wiring any of them in. `gwctl` and `ingress2gateway` are confirmed SIG-Network projects.

Repos that look like tools but are just **written guides** (do not chase them for automation): `KM3dd/nginx-to-traefik`, various SUSE/RKE2 and Medium walkthroughs, and the marketing microsite `ingressnginxmigration.org` (unverified provenance — treat with suspicion).

### The `kubernetesIngressNGINX` provider (the real Traefik-native mechanism)

Not a CLI, but the reason this migration is near-zero-touch: set `providers.kubernetesIngressNGINX.enabled=true` in Traefik static config and Traefik natively reads existing `Ingress` objects + translates most ingress-nginx annotations at runtime, deployable alongside ingress-nginx for a gradual cutover. Known open gaps (verified via Traefik issues): combining `kubernetesCRD` `Middleware` with this provider, and some ConfigMap-level annotations like `proxy-body-size` / `client-body-buffer-size`. Those gaps are exactly what the analyzers in this runbook exist to surface. Provider docs: <https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-ingress-nginx/>.

### Upstream recommendation — factor this into the target decision

- **ingress-nginx is archived / end-of-life (2026-03-24): no releases, no bugfixes, no CVE patches.** Staying put is a growing security liability, not a neutral hold. Successor "InGate" was also retired.
- The **neutral** upstream recommendation (Kubernetes SIG-Network + the Gateway API project) is **migrate to Gateway API**, and the single migration tool it endorses is **`ingress2gateway`** — the same tool in section 4. `traefik/ingress-nginx-migration` is official only within Traefik's own materials.
- Practical read: run the Traefik analyzers (this runbook) to score a Traefik-Ingress-compat cutover, **and** run `ingress2gateway` to see the Gateway API picture, then decide target (Traefik classic Ingress compat vs. Traefik Gateway API vs. another Gateway API implementation) with both reports in hand. The commands in sections 10-11 already produce both.

## 18. Post-deployment validation (`gwctl`) and capacity (`gateway-api-bench`)

Sections 10-11 are read-only *assessment*. These two run *after* you have applied converted Gateway API resources — do them in **staging first**, never blind against production.

### `gwctl` — what did the controller actually accept?

A scanner reporting "annotation supported" is not proof the controller accepted the route. `gwctl analyze` reads deployed Gateway API resources and surfaces `Accepted` / `ResolvedRefs` status, policy attachment, and relationships — i.e. the routes Traefik (or any Gateway API controller) actually **rejected or left unresolved**.

Install (persistent, into `$TOOLS_DIR` via Homebrew):

```bash
command -v gwctl >/dev/null || brew install gwctl
gwctl version 2>/dev/null || gwctl --help
```

Run after deploying the converted resources to a staging cluster:

```bash
# ensure you are pointed at the staging cluster/context first
gwctl get httproutes -A
gwctl describe httproutes -A            # per-route Accepted / ResolvedRefs conditions
gwctl analyze                           # relationships, policies, unresolved refs
```

Treat any route not `Accepted` / not `ResolvedRefs=True` as a migration gap to fix before touching production dns/cutover.

### `gateway-api-bench` — capacity, not correctness

Benchmarks a Gateway API controller under route churn, resource usage, and config-propagation latency. Useful before a large cutover, but:

- the published scenario is **5,000 routes** — it does **not** prove large-fleet capacity (e.g. hundreds of thousands of routes across a fleet). Build a route distribution that mirrors your real per-cluster inventory (use the `kubectl get ingress -A` counts from section 8).
- pair it with **real traffic replay** against staging; propagation latency and churn behavior under your actual annotation mix is what matters, not a synthetic uniform route set.
- verify the exact repo/org and install method before wiring it into CI — it was surfaced by survey and is not confirmed here.

## References

- Official Traefik analyzer: <https://github.com/traefik/ingress-nginx-migration>
- Traefik NGINX annotation compatibility: <https://doc.traefik.io/traefik/reference/routing-configuration/kubernetes/ingress-nginx/>
- `ing-switch`: <https://github.com/saiyam1814/ing-switch>
- `ingress2gateway`: <https://github.com/kubernetes-sigs/ingress2gateway>
- Kubernetes kubeconfig rules: <https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/>
- `nginx-traefik-converter`: <https://github.com/nikhilsbhat/nginx-traefik-converter>
- `ingress-migration-analyzer`: <https://github.com/ibexmonj/ingress-migration-analyzer>
- ShiftScope: <https://github.com/thc1006/shiftscope>
- Traefik `kubernetesIngressNGINX` provider: <https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/kubernetes-ingress-nginx/>
- Traefik helm chart releases (current chart/appVersion): <https://github.com/traefik/traefik-helm-chart/releases>
- ingress-nginx retirement announcement: <https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/>
- Gateway API "Migrating from Ingress-NGINX" (upstream guide): <https://gateway-api.sigs.k8s.io/guides/getting-started/migrating-from-ingress-nginx/>
- `ingress2eg` (Envoy Gateway converter): <https://github.com/kkk777-7/ingress2eg>
- HAProxy migration assistant: <https://www.haproxy.com/ingress-nginx-migration-assistant>
- kgateway migration guide: <https://kgateway.dev/blog/ingress-nginx-migration-gateway-api/>
- `gwctl` (Gateway API post-deploy analyzer): <https://github.com/kubernetes-sigs/gwctl>
- `gateway-api-bench` (controller benchmark; verify exact org): <https://github.com/kubernetes-sigs/gateway-api-bench>
