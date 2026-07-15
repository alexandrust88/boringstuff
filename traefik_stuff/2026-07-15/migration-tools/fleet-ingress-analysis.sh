#!/usr/bin/env bash
#
# fleet-ingress-analysis.sh
# =========================
#
# Generate ingress-nginx -> Traefik migration reports across a FLEET of
# Kubernetes clusters, then produce a fleet-wide "can I migrate this cluster
# to Traefik easily or not" summary.
#
# This is a fleet wrapper around section 11 of the runbook
# (analyze-ingress-nginx-to-traefik-macos.md). It uses the same tool names,
# flags, sanitize_name helper, per-context flattened-kubeconfig safety pattern,
# and file-permission discipline (chmod 0600/0700). Read that runbook first.
#
# WHAT IT DOES
#   1. Iterates over every kubeconfig file in a folder (one or many contexts each).
#   2. For each context: builds an isolated, flattened, --minify kubeconfig
#      (never mutates shared state, never runs `kubectl config use-context`),
#      checks reachability, then checks whether there is any nginx ingress at all.
#   3. Runs the OFFICIAL analyzer `ingress-nginx-migration` (json + markdown),
#      and optionally `ing-switch` and `ingress2gateway` if they are installed.
#      Per-cluster output is named  <clustername>_ingress_analysis.<ext>.
#   4. Aggregates every <cluster>_ingress_analysis.json into a fleet summary
#      (CSV + Markdown table + console counts) that classifies each cluster:
#         EASY       -> 0 unsupported, 0 snippets/unknowns
#         CAVEATS    -> 0 unsupported but has snippet/unknown annotations
#         HARD       -> some unsupported ingresses
#         NO-NGINX   -> no nginx ingress found; nothing to migrate
#         UNREACHABLE-> cluster-info failed
#         BLOCKED    -> reachable but the analyzer produced no usable JSON
#
# READ-ONLY. This script never applies anything to any cluster. It only lists
# ingresses / ingressclasses and runs read-only analyzers.
#
# USAGE
#   ./fleet-ingress-analysis.sh <KUBECONFIG_DIR> [OUTPUT_DIR]
#     <KUBECONFIG_DIR>  folder containing one or more kubeconfig files
#     [OUTPUT_DIR]      where reports go (default: ./fleet-reports)
#
#   Flags (may appear before or after the positional args):
#     --keep-kubeconfigs   do NOT delete the isolated per-context kubeconfigs
#                          at the end (they hold credentials; only for debugging)
#
# PREREQUISITES
#   Required:  kubectl, jq, and the official analyzer `ingress-nginx-migration`
#              (install per runbook sections 1-2).
#   Optional:  `ing-switch`      (runbook section 3)  -- richer json + html
#              `ingress2gateway` (runbook section 4)  -- Gateway API preview
#   Missing optional tools are skipped gracefully (command -v guard); the script
#   does not hard-fail when one is absent.
#
# ============================ BIG CAVEAT ==================================
# The jq aggregation at the bottom reads compatibility signals out of the
# official analyzer's JSON using ASSUMED field names
# (.unsupportedIngressCount, .totalIngressCount, snippet/unknown annotation
# counts). These names are NOT verified against the tool. The runbook itself
# flags `.unsupportedIngressCount` as an assumption (section 10). Before you
# trust the verdicts, confirm the real schema once:
#
#     ingress-nginx-migration --help
#     ingress-nginx-migration --ingress-class nginx \
#       --controller-class k8s.io/ingress-nginx --format json \
#       --output-file /tmp/sample.json
#     jq 'keys' /tmp/sample.json
#     jq '.'    /tmp/sample.json | less
#
# Then adjust the field-name candidate lists in extract_signal() below. Every
# candidate this script tries is listed there with a comment. If none match,
# the signal falls back to a safe value and the cluster is marked NEEDS-REVIEW
# rather than being silently reported as EASY.
# =========================================================================

set -uo pipefail
# Note: intentionally NOT `set -e`. A single cluster failing an analyzer must
# not abort the whole fleet. Every tool invocation is guarded with `|| true`
# and its stderr is captured to a per-cluster log file.

# --------------------------------------------------------------------------
# argument parsing
# --------------------------------------------------------------------------
KEEP_KUBECONFIGS=0
POSITIONAL=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep-kubeconfigs) KEEP_KUBECONFIGS=1 ;;
    -h|--help)
      # print the header comment block (everything up to the first blank
      # line after the leading '#' banner) and exit.
      sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "Unknown flag: $1" >&2
      echo "Usage: $0 <KUBECONFIG_DIR> [OUTPUT_DIR] [--keep-kubeconfigs]" >&2
      exit 2
      ;;
    *) POSITIONAL+=("$1") ;;
  esac
  shift
done

if [ "${#POSITIONAL[@]}" -lt 1 ]; then
  echo "Usage: $0 <KUBECONFIG_DIR> [OUTPUT_DIR] [--keep-kubeconfigs]" >&2
  exit 2
fi

KUBECONFIG_DIR="${POSITIONAL[0]}"
OUTPUT_DIR="${POSITIONAL[1]:-./fleet-reports}"

if [ ! -d "$KUBECONFIG_DIR" ]; then
  echo "Kubeconfig directory not found: $KUBECONFIG_DIR" >&2
  exit 2
fi

# --------------------------------------------------------------------------
# hard prerequisites
# --------------------------------------------------------------------------
for req in kubectl jq; do
  if ! command -v "$req" >/dev/null 2>&1; then
    echo "Required tool not found on PATH: $req" >&2
    exit 2
  fi
done

HAVE_OFFICIAL=0; command -v ingress-nginx-migration >/dev/null 2>&1 && HAVE_OFFICIAL=1
HAVE_INGSWITCH=0; command -v ing-switch          >/dev/null 2>&1 && HAVE_INGSWITCH=1
HAVE_ING2GW=0;    command -v ingress2gateway     >/dev/null 2>&1 && HAVE_ING2GW=1

if [ "$HAVE_OFFICIAL" -eq 0 ]; then
  echo "WARNING: 'ingress-nginx-migration' (the official analyzer) is not on PATH." >&2
  echo "         The fleet summary will have no compatibility signals to aggregate." >&2
  echo "         Install it per runbook section 2, or continue for optional tools only." >&2
fi

# --------------------------------------------------------------------------
# workspace layout
# --------------------------------------------------------------------------
# Absolute path so we can safely reference it regardless of cwd changes.
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

OFFICIAL_DIR="$OUTPUT_DIR/official"      # <cluster>_ingress_analysis.{json,md}
INGSWITCH_DIR="$OUTPUT_DIR/ing-switch"   # <cluster>_ingress_analysis.{json,html}
ING2GW_DIR="$OUTPUT_DIR/ingress2gateway" # <cluster>_ingress_analysis.{yaml,warnings.log}
LOG_DIR="$OUTPUT_DIR/logs"
KUBECONFIG_TMP_DIR="$OUTPUT_DIR/tmp-kubeconfigs"

mkdir -p "$OFFICIAL_DIR" "$INGSWITCH_DIR" "$ING2GW_DIR" "$LOG_DIR" "$KUBECONFIG_TMP_DIR"

# Reports and isolated kubeconfigs may contain hostnames, namespaces,
# annotation values, and credentials. Protect the whole tree (runbook section 9).
chmod 0700 "$OUTPUT_DIR" "$KUBECONFIG_TMP_DIR" 2>/dev/null || true

SUMMARY_CSV="$OUTPUT_DIR/fleet-summary.csv"
SUMMARY_MD="$OUTPUT_DIR/fleet-summary.md"

# rows accumulated during the loop; one line per context:
#   cluster|contexts|reachable|total|unsupported|snippets|verdict
ROWS_TMP="$(mktemp -t fleet-rows.XXXXXX)"

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

# sanitize_name: identical intent to the runbook's helper -- map a context or
# filename into something safe as a filename. Includes the empty-result hash
# fallback the runbook added (non-ASCII / all-punctuation names sanitize to
# empty and would otherwise collide).
sanitize_name() {
  local raw="$1" out
  out="$(printf '%s' "$raw" | tr '/:@ ' '____' | tr -cd '[:alnum:]_.-')"
  if [ -z "$out" ]; then
    out="ctx-$(printf '%s' "$raw" | shasum | cut -c1-8)"
  fi
  printf '%s' "$out"
}

# extract_signal <json-file> <signal>
# Pull one integer signal out of the official analyzer JSON, trying several
# likely field names in order and falling back to empty on no match.
#
# !!! FIELD NAMES BELOW ARE ASSUMPTIONS -- see the BIG CAVEAT at the top. !!!
# Confirm with `jq 'keys' <sample.json>` and edit these candidate lists.
extract_signal() {
  local file="$1" signal="$2"
  [ -s "$file" ] || { printf ''; return; }
  # `jq -r` over a "first non-null candidate" expression. Each `//` falls
  # through to the next candidate; the final `// empty` yields "" if none hit.
  case "$signal" in
    total)
      jq -r '
        (.totalIngressCount
         // .totalIngresses
         // .summary.totalIngresses
         // .summary.total
         // (.ingresses | length?)
         // empty)
      ' "$file" 2>/dev/null
      ;;
    unsupported)
      jq -r '
        (.unsupportedIngressCount
         // .unsupportedIngresses
         // .summary.unsupportedIngresses
         // .summary.unsupported
         // .incompatibleIngressCount
         // empty)
      ' "$file" 2>/dev/null
      ;;
    snippets)
      # snippet-annotation count: annotations like server-snippet /
      # configuration-snippet that the compat provider cannot fully honour.
      jq -r '
        (.snippetAnnotationCount
         // .snippetAnnotations
         // .summary.snippetAnnotations
         // .summary.snippets
         // empty)
      ' "$file" 2>/dev/null
      ;;
    unknown)
      # unknown / unrecognised annotation count.
      jq -r '
        (.unknownAnnotationCount
         // .unknownAnnotations
         // .summary.unknownAnnotations
         // .summary.unknown
         // empty)
      ' "$file" 2>/dev/null
      ;;
    *) printf '' ;;
  esac
}

# num_or <value> <default>: echo the value if it is a non-negative integer,
# otherwise the default. Keeps the CSV/verdict logic robust against nulls.
num_or() {
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *)           printf '%s' "$1" ;;
  esac
}

# --------------------------------------------------------------------------
# main loop -- iterate kubeconfig files, then contexts within each file
# --------------------------------------------------------------------------
# Sequential on purpose (runbook section 11): a first fleet pass should not
# simultaneously refresh auth plugins / hammer many API servers. To parallelize
# later, collect the (kubeconfig,context) pairs into an array and feed them to
# `xargs -P 5 -n 1` (or a small worker loop) calling a per-context function --
# keep the worker count small (e.g. 5) and keep each context's isolated
# kubeconfig + log files distinct (they already are, keyed by safe name).

shopt -s nullglob
kubeconfig_files=("$KUBECONFIG_DIR"/*)
shopt -u nullglob

if [ "${#kubeconfig_files[@]}" -eq 0 ]; then
  echo "No files found in $KUBECONFIG_DIR" >&2
  exit 2
fi

for kubeconfig_file in "${kubeconfig_files[@]}"; do
  [ -f "$kubeconfig_file" ] || continue

  file_stem="$(basename "$kubeconfig_file")"
  file_stem="${file_stem%.*}"   # strip a single extension for the fallback name

  # Enumerate contexts in this kubeconfig. If the file is not a valid
  # kubeconfig, skip it (logged, not fatal).
  contexts="$(kubectl --kubeconfig "$kubeconfig_file" config get-contexts -o name 2>>"$LOG_DIR/_enumerate.log" || true)"
  if [ -z "$contexts" ]; then
    echo "[$(date -u +%FT%TZ)] no contexts in $kubeconfig_file (not a kubeconfig?) -- skipping"
    continue
  fi

  while IFS= read -r context; do
    [ -n "$context" ] || continue

    # Prefer the context name; fall back to the kubeconfig filename stem.
    cluster_raw="$context"
    [ -n "$cluster_raw" ] || cluster_raw="$file_stem"
    cluster="$(sanitize_name "$cluster_raw")"

    isolated_kubeconfig="$KUBECONFIG_TMP_DIR/${cluster}.yaml"
    log_prefix="$LOG_DIR/${cluster}"

    echo "[$(date -u +%FT%TZ)] cluster=$cluster context=$context file=$(basename "$kubeconfig_file")"

    # ---- build an isolated, flattened, minified kubeconfig for THIS context
    # (runbook section 11: never mutate shared state, never use-context).
    if ! kubectl --kubeconfig "$kubeconfig_file" \
          --context "$context" \
          config view --raw --flatten --minify \
          > "$isolated_kubeconfig" 2>"${log_prefix}.kubeconfig-error.log"; then
      echo "  -> could not build isolated kubeconfig; marking UNREACHABLE"
      printf '%s|%s|no|0|0|0|UNREACHABLE\n' "$cluster" "$context" >> "$ROWS_TMP"
      continue
    fi
    chmod 0600 "$isolated_kubeconfig" 2>/dev/null || true

    # ---- reachability check (read-only). Skip cluster on failure.
    if ! KUBECONFIG="$isolated_kubeconfig" kubectl cluster-info \
          > "${log_prefix}.cluster-info.log" 2>&1; then
      echo "  -> cluster-info failed; marking UNREACHABLE"
      printf '%s|%s|no|0|0|0|UNREACHABLE\n' "$cluster" "$context" >> "$ROWS_TMP"
      continue
    fi

    # ---- detect the ingressClass/controller reality (read-only, informational)
    KUBECONFIG="$isolated_kubeconfig" kubectl get ingressclass \
      -o custom-columns=NAME:.metadata.name,CONTROLLER:.spec.controller \
      > "${log_prefix}.ingressclasses.txt" 2>>"${log_prefix}.ingressclasses.log" || true

    # ---- is there any nginx ingress at all? If not, skip the pointless scan.
    # Count Ingresses whose ingressClassName is nginx OR that carry the legacy
    # kubernetes.io/ingress.class=nginx annotation.
    nginx_count="$(
      KUBECONFIG="$isolated_kubeconfig" kubectl get ingress -A -o json 2>>"${log_prefix}.ingress-count.log" \
        | jq '[.items[]
                | select(
                    (.spec.ingressClassName == "nginx")
                    or ((.metadata.annotations["kubernetes.io/ingress.class"] // "") == "nginx")
                  )] | length' 2>/dev/null
    )"
    nginx_count="$(num_or "$nginx_count" 0)"

    if [ "$nginx_count" -eq 0 ]; then
      echo "  -> no nginx ingress found; nothing to migrate"
      printf '%s|%s|yes|0|0|0|NO-NGINX\n' "$cluster" "$context" >> "$ROWS_TMP"
      continue
    fi

    # ---- OFFICIAL analyzer: JSON (machine-readable, for aggregation)
    official_json="$OFFICIAL_DIR/${cluster}_ingress_analysis.json"
    official_md="$OFFICIAL_DIR/${cluster}_ingress_analysis.md"

    if [ "$HAVE_OFFICIAL" -eq 1 ]; then
      KUBECONFIG="$isolated_kubeconfig" \
      ingress-nginx-migration \
        --ingress-class nginx \
        --controller-class k8s.io/ingress-nginx \
        --format json \
        --output-file "$official_json" \
        > /dev/null 2> "${log_prefix}.official-json.log" || true

      # OFFICIAL analyzer: compact Markdown summary (human-readable)
      KUBECONFIG="$isolated_kubeconfig" \
      ingress-nginx-migration \
        --ingress-class nginx \
        --controller-class k8s.io/ingress-nginx \
        --format markdown \
        --summary \
        --output-file "$official_md" \
        > /dev/null 2> "${log_prefix}.official-markdown.log" || true
    fi

    # ---- ing-switch (optional): JSON analysis + HTML report.
    # ing-switch supports --kubeconfig/--context directly (runbook table),
    # but we point it at the isolated single-context kubeconfig so behaviour
    # matches the official tool and there is no shared-state surprise.
    if [ "$HAVE_INGSWITCH" -eq 1 ]; then
      ing-switch \
        --kubeconfig "$isolated_kubeconfig" \
        analyze --target traefik --output json \
        > "$INGSWITCH_DIR/${cluster}_ingress_analysis.json" \
        2> "${log_prefix}.ing-switch-json.log" || true

      ing-switch \
        --kubeconfig "$isolated_kubeconfig" \
        report --target traefik \
        --output "$INGSWITCH_DIR/${cluster}_ingress_analysis.html" \
        > "${log_prefix}.ing-switch-html.log" 2>&1 || true
    fi

    # ---- ingress2gateway (optional): Gateway API YAML preview + warnings.
    if [ "$HAVE_ING2GW" -eq 1 ]; then
      KUBECONFIG="$isolated_kubeconfig" \
      ingress2gateway print \
        --providers ingress-nginx \
        --ingress-nginx-ingress-class nginx \
        --all-namespaces \
        --output yaml \
        > "$ING2GW_DIR/${cluster}_ingress_analysis.yaml" \
        2> "$ING2GW_DIR/${cluster}_ingress_analysis.warnings.log" || true
    fi

    # ---- extract compatibility signals from the OFFICIAL JSON for the summary.
    total="$(num_or "$(extract_signal "$official_json" total)" "$nginx_count")"
    unsupported_raw="$(extract_signal "$official_json" unsupported)"
    snippets_raw="$(extract_signal "$official_json" snippets)"
    unknown_raw="$(extract_signal "$official_json" unknown)"

    unsupported="$(num_or "$unsupported_raw" 0)"
    snippets="$(num_or "$snippets_raw" 0)"
    unknown="$(num_or "$unknown_raw" 0)"

    # ---- verdict tiers.
    if [ "$HAVE_OFFICIAL" -eq 0 ] || [ ! -s "$official_json" ]; then
      # Reachable, has nginx ingresses, but no usable analyzer JSON produced.
      verdict="BLOCKED"
    elif [ -z "$unsupported_raw" ] && [ -z "$snippets_raw" ] && [ -z "$unknown_raw" ]; then
      # None of the assumed field names matched -> we genuinely don't know.
      # Do NOT silently call this EASY (see BIG CAVEAT). Flag for review.
      verdict="NEEDS-REVIEW"
    elif [ "$unsupported" -gt 0 ]; then
      verdict="HARD"
    elif [ "$snippets" -gt 0 ] || [ "$unknown" -gt 0 ]; then
      verdict="CAVEATS"
    else
      verdict="EASY"
    fi

    echo "  -> total=$total unsupported=$unsupported snippets=$snippets unknown=$unknown verdict=$verdict"
    printf '%s|%s|yes|%s|%s|%s|%s\n' \
      "$cluster" "$context" "$total" "$unsupported" "$snippets" "$verdict" >> "$ROWS_TMP"

  done <<< "$contexts"
done

# --------------------------------------------------------------------------
# fleet summary -- CSV + Markdown, easiest clusters first
# --------------------------------------------------------------------------
# Verdict sort order (ascending = easiest first):
#   EASY(0) CAVEATS(1) NO-NGINX(2) NEEDS-REVIEW(3) HARD(4) BLOCKED(5) UNREACHABLE(6)
verdict_rank() {
  case "$1" in
    EASY)         echo 0 ;;
    CAVEATS)      echo 1 ;;
    NO-NGINX)     echo 2 ;;
    NEEDS-REVIEW) echo 3 ;;
    HARD)         echo 4 ;;
    BLOCKED)      echo 5 ;;
    UNREACHABLE)  echo 6 ;;
    *)            echo 9 ;;
  esac
}

# Build a sortable stream: "<rank> <original-line>", sort, then strip the rank.
SORTED_TMP="$(mktemp -t fleet-sorted.XXXXXX)"
if [ -s "$ROWS_TMP" ]; then
  while IFS='|' read -r cluster context reachable total unsupported snippets verdict; do
    [ -n "$cluster" ] || continue
    printf '%s\t%s|%s|%s|%s|%s|%s|%s\n' \
      "$(verdict_rank "$verdict")" \
      "$cluster" "$context" "$reachable" "$total" "$unsupported" "$snippets" "$verdict"
  done < "$ROWS_TMP" | sort -t'	' -k1,1n -k2,2 | cut -f2- > "$SORTED_TMP"
fi

# ---- CSV
{
  echo "cluster,context,reachable,total_ingresses,unsupported,snippets,verdict"
  if [ -s "$SORTED_TMP" ]; then
    while IFS='|' read -r cluster context reachable total unsupported snippets verdict; do
      [ -n "$cluster" ] || continue
      printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$cluster" "$context" "$reachable" "$total" "$unsupported" "$snippets" "$verdict"
    done < "$SORTED_TMP"
  fi
} > "$SUMMARY_CSV"

# ---- Markdown table
{
  echo "# Fleet ingress-nginx -> Traefik migration summary"
  echo
  echo "Generated: $(date -u +%FT%TZ)"
  echo
  echo "Sorted easiest-to-migrate first. Verdicts: EASY, CAVEATS, NO-NGINX,"
  echo "NEEDS-REVIEW, HARD, BLOCKED, UNREACHABLE."
  echo
  echo "> CAVEAT: 'total/unsupported/snippets' are read from the official"
  echo "> analyzer JSON using ASSUMED field names. Confirm the schema"
  echo "> (\`jq 'keys' <sample.json>\`) and adjust extract_signal() in the script."
  echo "> Rows marked NEEDS-REVIEW are where none of the assumed fields matched."
  echo
  echo "| cluster | context | reachable | total | unsupported | snippets | verdict |"
  echo "| --- | --- | --- | ---: | ---: | ---: | --- |"
  if [ -s "$SORTED_TMP" ]; then
    while IFS='|' read -r cluster context reachable total unsupported snippets verdict; do
      [ -n "$cluster" ] || continue
      printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
        "$cluster" "$context" "$reachable" "$total" "$unsupported" "$snippets" "$verdict"
    done < "$SORTED_TMP"
  fi
} > "$SUMMARY_MD"

# --------------------------------------------------------------------------
# console summary -- counts per tier + where the reports live
# --------------------------------------------------------------------------
count_tier() { [ -s "$SORTED_TMP" ] && grep -c "|$1$" "$SORTED_TMP" 2>/dev/null || echo 0; }

total_rows=0
[ -s "$SORTED_TMP" ] && total_rows="$(wc -l < "$SORTED_TMP" | tr -d ' ')"

echo
echo "=================== FLEET SUMMARY ==================="
echo "clusters/contexts analyzed : $total_rows"
echo "  EASY         : $(count_tier EASY)"
echo "  CAVEATS      : $(count_tier CAVEATS)"
echo "  NO-NGINX     : $(count_tier NO-NGINX)"
echo "  NEEDS-REVIEW : $(count_tier NEEDS-REVIEW)"
echo "  HARD         : $(count_tier HARD)"
echo "  BLOCKED      : $(count_tier BLOCKED)"
echo "  UNREACHABLE  : $(count_tier UNREACHABLE)"
echo "----------------------------------------------------"
echo "per-cluster reports : $OFFICIAL_DIR (json + md)"
[ "$HAVE_INGSWITCH" -eq 1 ] && echo "ing-switch reports  : $INGSWITCH_DIR (json + html)"
[ "$HAVE_ING2GW" -eq 1 ]    && echo "ingress2gateway     : $ING2GW_DIR (yaml + warnings)"
echo "logs                : $LOG_DIR"
echo "fleet summary (csv) : $SUMMARY_CSV"
echo "fleet summary (md)  : $SUMMARY_MD"
echo "===================================================="

# --------------------------------------------------------------------------
# cleanup (runbook section 16)
# --------------------------------------------------------------------------
# The isolated kubeconfigs hold credentials. Remove them unless asked to keep.
rm -f "$ROWS_TMP" "$SORTED_TMP" 2>/dev/null || true

if [ "$KEEP_KUBECONFIGS" -eq 1 ]; then
  echo "NOTE: --keep-kubeconfigs set; isolated kubeconfigs LEFT in $KUBECONFIG_TMP_DIR"
  echo "      They contain credentials -- delete them when done: rm -rf '$KUBECONFIG_TMP_DIR'"
else
  rm -rf "$KUBECONFIG_TMP_DIR" 2>/dev/null || true
fi

exit 0
