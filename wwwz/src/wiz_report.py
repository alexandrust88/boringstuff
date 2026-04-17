#!/usr/bin/env python3
"""
generate wiz vulnerability reports grouped by kubernetes namespace.

uses generators for memory-efficient iteration over large datasets.
deduplicates CVEs globally - same CVE across multiple pods/namespaces
is consolidated into one entry with a list of affected locations.

outputs:
  - wiz-report/<namespace>.json   per-namespace CVE details
  - wiz-report/summary.json       severity counts per namespace
  - wiz_report_all_namespaces.csv  flat csv of all findings
  - wiz_report_summary.html        human-readable dashboard with CVE details
"""

from dotenv import load_dotenv
import argparse
import os
import csv
import json
import html as html_mod
import time
import threading
import requests
import urllib3
from pathlib import Path
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from typing import Generator, Iterator

urllib3.disable_warnings()
load_dotenv(dotenv_path=".env", override=False)

# ---------------------
# configuration
# ---------------------

WIZ_AUTH_URL = os.getenv(
    "WIZ_AUTH_URL", "https://auth.app.wiz.io/oauth/token",
)
WIZ_API_URL = os.getenv(
    "WIZ_API_URL", "https://api.eu18.app.wiz.io/graphql",
)

# output dir is overridable via env for container deployment
OUTPUT_ROOT = Path(os.getenv("OUTPUT_DIR", "."))
OUTPUT_DIR = OUTPUT_ROOT / "wiz-report"
TEAMS_WEBHOOK_URL = os.getenv("TEAMS_WEBHOOK_URL", "")
MAX_WORKERS = int(os.getenv("MAX_WORKERS", "5"))
MAX_RETRIES = 3

IGNORE_NAMESPACES = {
    "kube-system",
    "gatekeeper-system",
    "kube-node-lease",
    "kube-public",
}

SEVERITY_ORDER = {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}
SEV_PREFIX = "VULNERABILITYSEVERITY"

# ---------------------
# graphql
# ---------------------

GRAPH_SEARCH = """
query GraphSearch(
  $query: GraphEntityQueryInput
  $first: Int
  $after: String
) {
  graphSearch(query: $query, first: $first, after: $after) {
    nodes {
      entities { id name type properties }
    }
    pageInfo { hasNextPage endCursor }
    totalCount
  }
}
"""

CLUSTER_QUERY_OBJ = {
    "type": ["KUBERNETES_CLUSTER"],
    "select": True,
    "where": {"name": {"CONTAINS": ["caas"]}},
}


def _vuln_query_obj(cluster_name: str) -> dict:
    """build graphSearch query input for a cluster."""
    return {
        "type": ["CONTAINER"],
        "select": True,
        "relationships": [
            {
                "type": [{"type": "CONTAINS", "reverse": True}],
                "with": {
                    "type": ["KUBERNETES_CLUSTER"],
                    "select": True,
                    "where": {
                        "name": {"CONTAINS": [cluster_name]},
                    },
                },
            },
            {
                "type": [{"type": "CONTAINS", "reverse": True}],
                "with": {"type": ["POD"], "select": True},
            },
            {
                "type": [{"type": "CONTAINS", "reverse": True}],
                "with": {"type": ["NAMESPACE"], "select": True},
            },
            {
                "type": [{"type": "INSTANCE_OF"}],
                "with": {
                    "type": ["CONTAINER_IMAGE"],
                    "select": True,
                    "relationships": [
                        {
                            "type": [
                                {
                                    "type": "ALERTED_ON",
                                    "reverse": True,
                                },
                            ],
                            "with": {
                                "type": ["SECURITY_TOOL_FINDING"],
                                "select": True,
                                "where": {
                                    "severity": {
                                        "EQUALS": [
                                            "VulnerabilitySeverityCritical",
                                            "VulnerabilitySeverityHigh",
                                            "VulnerabilitySeverityMedium",
                                            "VulnerabilitySeverityLow",
                                        ],
                                    },
                                },
                                "relationships": [
                                    {
                                        "type": [
                                            {
                                                "type": "CAUSES",
                                                "reverse": True,
                                            },
                                        ],
                                        "with": {
                                            "type": ["VULNERABILITY"],
                                            "select": True,
                                        },
                                    },
                                ],
                            },
                        },
                    ],
                },
            },
        ],
    }


# ---------------------
# auth
# ---------------------


def get_token(client_id: str, client_secret: str) -> str:
    r = requests.post(
        WIZ_AUTH_URL,
        data={
            "client_id": client_id,
            "client_secret": client_secret,
            "audience": "wiz-api",
            "grant_type": "client_credentials",
        },
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
        },
        verify=False,
        timeout=30,
    )
    r.raise_for_status()
    return r.json()["access_token"]


# ---------------------
# rate limiter (wiz: 10 req/s per service account)
# ---------------------


class RateLimiter:
    def __init__(self, max_per_second: float = 8.0):
        self._interval = 1.0 / max_per_second
        self._lock = threading.Lock()
        self._last = 0.0

    def wait(self):
        with self._lock:
            now = time.monotonic()
            gap = now - self._last
            if gap < self._interval:
                time.sleep(self._interval - gap)
            self._last = time.monotonic()


_rate = RateLimiter()


# ---------------------
# api client with retry
# ---------------------


def wiz_graphql(
    token: str,
    query: str,
    variables: dict | None = None,
) -> dict:
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    }
    payload = {"query": query}
    if variables:
        payload["variables"] = variables

    last_err = None
    for attempt in range(1, MAX_RETRIES + 1):
        _rate.wait()
        try:
            r = requests.post(
                WIZ_API_URL,
                json=payload,
                headers=headers,
                verify=False,
                timeout=120,
            )
            if r.status_code == 429:
                wait = 2 ** attempt
                print(f"  rate limited, waiting {wait}s...")
                time.sleep(wait)
                last_err = RuntimeError("rate limited")
                continue
            r.raise_for_status()
            body = r.json()
            if "errors" in body:
                raise RuntimeError(
                    f"graphql errors: {body['errors']}"
                )
            return body
        except Exception as e:
            last_err = e
            if attempt == MAX_RETRIES:
                raise
            wait = 2 ** attempt
            print(
                f"  retry {attempt}/{MAX_RETRIES}"
                f" after {wait}s: {e}"
            )
            time.sleep(wait)

    raise last_err or RuntimeError("all retries exhausted")


# ---------------------
# data fetching - generators for memory efficiency
# ---------------------


def fetch_clusters(token: str) -> list[str]:
    result = wiz_graphql(token, GRAPH_SEARCH, {
        "query": CLUSTER_QUERY_OBJ,
        "first": 100,
    })
    nodes = (
        (result or {})
        .get("data", {})
        .get("graphSearch", {})
        .get("nodes", [])
    )
    clusters = []
    for n in nodes:
        entities = n.get("entities") or []
        if entities and entities[0].get("name"):
            clusters.append(entities[0]["name"])
    return clusters


def iter_cluster_pages(
    token: str,
    cluster: str,
) -> Generator[list[dict], None, None]:
    """yield pages of raw nodes for one cluster."""
    query_obj = _vuln_query_obj(cluster)
    cursor = None
    total = 0

    while True:
        variables = {"query": query_obj, "first": 500}
        if cursor:
            variables["after"] = cursor

        result = wiz_graphql(token, GRAPH_SEARCH, variables)
        search = (
            (result or {})
            .get("data", {})
            .get("graphSearch", {})
        )
        nodes = search.get("nodes") or []
        if nodes:
            yield nodes
            total += len(nodes)

        page_info = search.get("pageInfo") or {}
        if not page_info.get("hasNextPage"):
            break
        cursor = page_info.get("endCursor")
        if not cursor:
            break
        if total >= 10000:
            print(
                f"  {cluster}: hit 10k cap,"
                " results may be incomplete"
            )
            break

    print(f"  {cluster}: {total} findings")


def iter_cluster_nodes(
    token: str,
    cluster: str,
) -> Generator[dict, None, None]:
    """yield individual nodes for one cluster."""
    for page in iter_cluster_pages(token, cluster):
        yield from page


def fetch_all_nodes(
    token: str,
    cluster_filter: str | None = None,
    max_clusters: int | None = None,
) -> list[dict]:
    """fetch nodes from all (or filtered) clusters concurrently."""
    clusters = fetch_clusters(token)

    if cluster_filter:
        clusters = [
            c for c in clusters
            if cluster_filter.lower() in c.lower()
        ]
    if max_clusters and max_clusters > 0:
        clusters = clusters[:max_clusters]

    print(f"targeting {len(clusters)} clusters")

    def _collect(cluster):
        return list(iter_cluster_nodes(token, cluster))

    all_nodes = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as pool:
        futures = {
            pool.submit(_collect, c): c
            for c in clusters
        }
        for future in as_completed(futures):
            cluster = futures[future]
            try:
                all_nodes.extend(future.result())
            except Exception as e:
                print(f"  error fetching {cluster}: {e}")

    return all_nodes


# ---------------------
# normalization - generators
# ---------------------


def _strip_sev(raw) -> str:
    if not raw or not isinstance(raw, str):
        return "UNKNOWN"
    s = raw.upper()
    if s.startswith(SEV_PREFIX):
        s = s[len(SEV_PREFIX):]
    return s


def _safe_str(val) -> str:
    if val is None:
        return ""
    if isinstance(val, str):
        return val
    return str(val)


def normalize(node: dict) -> dict:
    """extract a flat record from a graphSearch node.

    extracts full CVE details from VULNERABILITY entity properties.
    """
    record = {
        "cluster": "",
        "namespace": "",
        "pod": "",
        "container": "",
        "image": "",
        "finding_name": "",
        "finding_severity": "UNKNOWN",
        "cve_id": "",
        "cve_description": "",
        "cve_severity": "UNKNOWN",
        "cve_score": "",
        "cve_exploitable": "",
        "cve_has_exploit": "",
        "cve_fix_version": "",
        "cve_link": "",
        "cve_published": "",
    }
    if not isinstance(node, dict):
        return record

    for e in node.get("entities") or []:
        if not isinstance(e, dict):
            continue
        t = e.get("type")
        name = _safe_str(e.get("name"))
        props = e.get("properties")
        if not isinstance(props, dict):
            props = {}

        if t == "CONTAINER":
            record["container"] = name
        elif t == "KUBERNETES_CLUSTER":
            record["cluster"] = name
        elif t == "NAMESPACE":
            record["namespace"] = name
        elif t == "POD":
            record["pod"] = name
        elif t == "CONTAINER_IMAGE":
            record["image"] = name
        elif t == "SECURITY_TOOL_FINDING":
            record["finding_name"] = name
            record["finding_severity"] = _strip_sev(
                props.get("severity")
            )
            # finding is a fallback source - only fill empty fields
            _fill = {
                "cve_description": (
                    props.get("CVEDescription")
                    or props.get("description")
                ),
                "cve_score": props.get("score"),
                "cve_link": (
                    props.get("portalUrl")
                    or props.get("link")
                ),
                "cve_has_exploit": props.get("hasExploit"),
            }
            for k, v in _fill.items():
                if not record[k] and v is not None:
                    record[k] = _safe_str(v)
            # fix version from finding
            if not record["cve_fix_version"]:
                if props.get("hasFix"):
                    record["cve_fix_version"] = _safe_str(
                        props.get("remediation") or ""
                    )
        elif t == "VULNERABILITY":
            # vulnerability is the authoritative source -
            # always overwrite with non-empty values
            record["cve_id"] = name
            sev = _strip_sev(props.get("severity"))
            if sev != "UNKNOWN":
                record["cve_severity"] = sev
            _vuln = {
                "cve_description": (
                    props.get("CVEDescription")
                    or props.get("description")
                ),
                "cve_score": props.get("score"),
                "cve_exploitable": (
                    props.get("exploitabilityScore")
                ),
                "cve_has_exploit": props.get("hasExploit"),
                "cve_fix_version": props.get("fixedVersion"),
                "cve_link": (
                    props.get("link")
                    or props.get("portalUrl")
                ),
                "cve_published": props.get("publishedDate"),
            }
            for k, v in _vuln.items():
                if v is not None:
                    record[k] = _safe_str(v)
    return record


def iter_normalized(
    nodes: list[dict],
) -> Generator[dict, None, None]:
    """generator: normalize nodes, skip failures."""
    for node in nodes:
        try:
            yield normalize(node)
        except Exception:
            continue


# ---------------------
# deduplication - global CVE registry
# ---------------------


class CveRegistry:
    """deduplicate CVEs globally.

    same CVE affecting multiple pods/namespaces/images gets one entry
    with a list of all affected locations.
    """

    def __init__(self):
        # cve_id -> cve details dict
        self.cves: dict[str, dict] = {}
        # cve_id -> set of (cluster, namespace, image) tuples
        self._locations: dict[str, set[tuple]] = defaultdict(set)
        # cluster -> set of cve_ids
        self.by_cluster: dict[str, set[str]] = defaultdict(set)
        # namespace -> set of cve_ids
        self.by_namespace: dict[str, set[str]] = defaultdict(set)
        # image -> set of cve_ids
        self.by_image: dict[str, set[str]] = defaultdict(set)
        # namespace -> set of clusters
        self.ns_clusters: dict[str, set[str]] = defaultdict(set)

    def add(self, record: dict):
        cve_id = record["cve_id"] or record["finding_name"]
        if not cve_id:
            return

        ns = record["namespace"] or "unknown"
        if ns in IGNORE_NAMESPACES:
            return

        # store/update CVE details (first seen wins for desc)
        if cve_id not in self.cves:
            self.cves[cve_id] = {
                "cve_id": cve_id,
                "severity": (
                    record["cve_severity"]
                    if record["cve_severity"] != "UNKNOWN"
                    else record["finding_severity"]
                ),
                "description": record["cve_description"],
                "score": record["cve_score"],
                "exploitable": record["cve_exploitable"],
                "has_exploit": record["cve_has_exploit"],
                "fix_version": record["cve_fix_version"],
                "link": record["cve_link"],
                "published": record["cve_published"],
                "affected": [],
            }

        loc = (
            record["cluster"],
            ns,
            record["image"],
        )
        if loc not in self._locations[cve_id]:
            self._locations[cve_id].add(loc)
            self.cves[cve_id]["affected"].append({
                "cluster": record["cluster"],
                "namespace": ns,
                "image": record["image"],
                "pod": record["pod"],
                "container": record["container"],
            })

        cluster = record["cluster"]
        if cluster:
            self.by_cluster[cluster].add(cve_id)
            self.ns_clusters[ns].add(cluster)
        self.by_namespace[ns].add(cve_id)
        if record["image"]:
            self.by_image[record["image"]].add(cve_id)

    def ingest(self, records: Iterator[dict]):
        """stream records into the registry."""
        for r in records:
            self.add(r)

    def namespace_cves(
        self, ns: str,
    ) -> list[dict]:
        """CVEs for a namespace, sorted by severity."""
        cve_ids = self.by_namespace.get(ns, set())
        cves = [self.cves[c] for c in cve_ids if c in self.cves]
        cves.sort(key=lambda c: SEVERITY_ORDER.get(
            c["severity"], 99
        ))
        return cves

    def image_cves(
        self, image: str,
    ) -> list[dict]:
        """CVEs for an image, sorted by severity."""
        cve_ids = self.by_image.get(image, set())
        cves = [self.cves[c] for c in cve_ids if c in self.cves]
        cves.sort(key=lambda c: SEVERITY_ORDER.get(
            c["severity"], 99
        ))
        return cves

    def top_images(self, n: int = 20) -> list[tuple[str, dict]]:
        """top N images by critical+high CVE count."""
        scored = []
        for img, cve_ids in self.by_image.items():
            counts = defaultdict(int)
            for cid in cve_ids:
                cve = self.cves.get(cid, {})
                counts[cve.get("severity", "UNKNOWN")] += 1
            scored.append((img, dict(counts)))
        scored.sort(key=lambda x: (
            x[1].get("CRITICAL", 0),
            x[1].get("HIGH", 0),
        ), reverse=True)
        return scored[:n]

    def namespace_summary(self) -> dict:
        """severity counts per namespace."""
        # pre-index images per namespace to avoid O(n*m) scan
        ns_images: dict[str, set[str]] = defaultdict(set)
        for cid, cve in self.cves.items():
            for loc in cve.get("affected", []):
                ns = loc.get("namespace", "")
                img = loc.get("image", "")
                if ns and img:
                    ns_images[ns].add(img)

        summary = {}
        for ns, cve_ids in sorted(self.by_namespace.items()):
            counts = defaultdict(int)
            for cid in cve_ids:
                cve = self.cves.get(cid, {})
                counts[cve.get("severity", "UNKNOWN")] += 1
            summary[ns] = {
                "unique_cves": len(cve_ids),
                "unique_images": len(ns_images.get(ns, set())),
                "by_severity": dict(counts),
            }
        return summary

    @property
    def total_unique(self) -> int:
        return len(self.cves)

    @property
    def sev_totals(self) -> dict[str, int]:
        """single-pass severity counts across all CVEs."""
        counts: dict[str, int] = defaultdict(int)
        for c in self.cves.values():
            counts[c["severity"]] += 1
        return dict(counts)


# ---------------------
# flat record generator for CSV (streams from registry)
# ---------------------


def iter_flat_records(
    registry: CveRegistry,
) -> Generator[dict, None, None]:
    """yield one row per (cve, affected location) for CSV."""
    for cve in registry.cves.values():
        for loc in cve["affected"]:
            yield {
                "cve_id": cve["cve_id"],
                "cve_severity": cve["severity"],
                "cve_score": cve["score"],
                "cve_description": cve["description"],
                "cve_fix_version": cve["fix_version"],
                "cve_exploitable": cve["exploitable"],
                "cve_has_exploit": cve["has_exploit"],
                "cve_link": cve["link"],
                "cve_published": cve["published"],
                "cluster": loc["cluster"],
                "namespace": loc["namespace"],
                "image": loc["image"],
                "pod": loc["pod"],
                "container": loc["container"],
            }


# ---------------------
# export: json per namespace
# ---------------------


def export_namespace_json(registry: CveRegistry):
    for ns in registry.by_namespace:
        cves = registry.namespace_cves(ns)
        out = OUTPUT_DIR / f"{ns}.json"
        out.write_text(json.dumps({
            "namespace": ns,
            "generated": _now_iso(),
            "unique_cves": len(cves),
            "cves": cves,
        }, indent=2, sort_keys=True, default=str),
            encoding="utf-8",
        )


# ---------------------
# export: csv - uses generator, streams rows
# ---------------------

CSV_FIELDS = [
    "cve_id", "cve_severity", "cve_score",
    "cve_has_exploit", "cve_description",
    "cve_fix_version", "cve_exploitable",
    "cve_link", "cve_published",
    "cluster", "namespace", "image",
    "pod", "container",
]


def export_csv(registry: CveRegistry):
    path = OUTPUT_ROOT / "wiz_report_all_namespaces.csv"
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(
            f, fieldnames=CSV_FIELDS, extrasaction="ignore",
        )
        w.writeheader()
        for row in iter_flat_records(registry):
            w.writerow({k: row.get(k, "") for k in CSV_FIELDS})


# ---------------------
# export: summary json
# ---------------------


def export_summary_json(registry: CveRegistry):
    out = OUTPUT_DIR / "summary.json"
    out.write_text(json.dumps({
        "generated": _now_iso(),
        "total_unique_cves": registry.total_unique,
        "namespaces": registry.namespace_summary(),
    }, indent=2, sort_keys=True), encoding="utf-8")


# ---------------------
# helpers
# ---------------------


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _now_short() -> str:
    return datetime.now(timezone.utc).strftime(
        "%Y-%m-%d %H:%M utc"
    )


# ---------------------
# export: html - interactive dashboard
# ---------------------


def _h(text: str) -> str:
    return html_mod.escape(str(text))


def _sev_class(sev: str) -> str:
    return {
        "CRITICAL": "crit", "HIGH": "high",
        "MEDIUM": "med", "LOW": "low",
    }.get(sev, "")


def _short_img(img: str) -> str:
    return img.rsplit("/", 1)[-1] if "/" in img else img


def _cve_row(c: dict, context_col: str, clusters: str = "") -> str:
    sev = c.get("severity", "UNKNOWN")
    cls = _sev_class(sev)
    raw_desc = c.get("description", "") or ""
    desc = _h(raw_desc[:200])
    if len(raw_desc) > 200:
        desc += "..."
    link = c.get("link", "")
    cve_cell = (
        f'<a href="{_h(link)}" target="_blank">'
        f'{_h(c["cve_id"])}</a>'
        if link else _h(c.get("cve_id", ""))
    )
    exploit = ""
    if c.get("has_exploit") in ("True", "true", True):
        exploit = '<span class="crit">YES</span>'
    return (
        f'<tr data-sev="{sev}" data-clusters="{_h(clusters)}">'
        f'<td>{cve_cell}</td>'
        f'<td class="{cls}">{sev}</td>'
        f'<td>{_h(c.get("score", ""))}</td>'
        f'<td>{exploit}</td>'
        f'<td>{_h(c.get("fix_version", ""))}</td>'
        f'<td class="desc">{desc}</td>'
        f'<td class="ctx">{context_col}</td>'
        f'</tr>'
    )


def _trunc(items: list[str], limit: int = 5) -> str:
    out = ", ".join(_h(i) for i in items[:limit])
    if len(items) > limit:
        out += f" +{len(items) - limit} more"
    return out


def export_html(
    registry: CveRegistry,
    diff: dict | None = None,
):
    summary = registry.namespace_summary()
    top_imgs = registry.top_images(20)
    totals = registry.sev_totals
    all_clusters = sorted(registry.by_cluster.keys())
    all_ns = sorted(registry.by_namespace.keys())

    # --- diff banner ---
    diff_html = ""
    if diff and not diff.get("first_run"):
        d = diff.get("delta", {})
        cls_c = ("up" if d.get("CRITICAL", 0) > 0
                 else "down" if d.get("CRITICAL", 0) < 0
                 else "flat")
        cls_h = ("up" if d.get("HIGH", 0) > 0
                 else "down" if d.get("HIGH", 0) < 0
                 else "flat")
        diff_html = (
            f'<div class="diff-banner">'
            f'<strong>diff vs previous run:</strong> '
            f'<span class="{cls_c}">'
            f'{d.get("CRITICAL", 0):+d} critical</span>, '
            f'<span class="{cls_h}">'
            f'{d.get("HIGH", 0):+d} high</span>, '
            f'total {diff.get("previous_total", 0)}'
            f' → {diff.get("current_total", 0)}'
            f'</div>'
        )

    # --- build nav sidebar items ---
    nav_clusters = "\n".join(
        f'<li><a href="#cluster-{_h(c)}" class="nav-link"'
        f' data-cluster="{_h(c)}">{_h(c)}</a></li>'
        for c in all_clusters
    )
    nav_ns = "\n".join(
        f'<li><a href="#{_h(ns)}" class="nav-link">'
        f'{_h(ns)}</a></li>'
        for ns in sorted(summary, key=lambda n: (
            -summary[n]["by_severity"].get("CRITICAL", 0),
            -summary[n]["by_severity"].get("HIGH", 0),
        ))
    )

    # --- cards ---
    cards_data = (
        ("clusters", len(all_clusters), ""),
        ("namespaces", len(summary), ""),
        ("unique cves", registry.total_unique, ""),
        ("critical", totals.get("CRITICAL", 0), "crit"),
        ("high", totals.get("HIGH", 0), "high"),
        ("medium", totals.get("MEDIUM", 0), "med"),
        ("low", totals.get("LOW", 0), "low"),
    )
    cards_html = "\n".join(
        f'<div class="card {cls}">'
        f'<div class="label">{label}</div>'
        f'<div class="value">{val}</div>'
        f'</div>'
        for label, val, cls in cards_data
    )

    # --- filter options ---
    cluster_opts = "\n".join(
        f'<option value="{_h(c)}">{_h(c)}</option>'
        for c in all_clusters
    )
    ns_opts = "\n".join(
        f'<option value="{_h(ns)}">{_h(ns)}</option>'
        for ns in all_ns
    )

    def _sorted_ns():
        return sorted(summary, key=lambda n: (
            -summary[n]["by_severity"].get("CRITICAL", 0),
            -summary[n]["by_severity"].get("HIGH", 0),
        ))

    # --- namespace summary table ---
    ns_rows = []
    for ns in _sorted_ns():
        s = summary[ns]
        sev = s["by_severity"]
        cl = ",".join(sorted(registry.ns_clusters.get(ns, set())))
        ns_rows.append(
            f'<tr data-ns="{_h(ns)}" data-clusters="{_h(cl)}">'
            f'<td><a href="#{_h(ns)}">{_h(ns)}</a></td>'
            f'<td class="num">{s["unique_cves"]}</td>'
            f'<td class="num">{s["unique_images"]}</td>'
            f'<td class="num crit">'
            f'{sev.get("CRITICAL", 0)}</td>'
            f'<td class="num high">'
            f'{sev.get("HIGH", 0)}</td>'
            f'<td class="num med">'
            f'{sev.get("MEDIUM", 0)}</td>'
            f'<td class="num low">'
            f'{sev.get("LOW", 0)}</td>'
            f'</tr>'
        )

    # --- top images table ---
    img_rows = []
    for img, sevs in top_imgs:
        short = _short_img(img)
        img_rows.append(
            f'<tr><td title="{_h(img)}">'
            f'<a href="#img-{_h(short)}">{_h(short)}</a></td>'
            f'<td class="num crit">'
            f'{sevs.get("CRITICAL", 0)}</td>'
            f'<td class="num high">'
            f'{sevs.get("HIGH", 0)}</td>'
            f'<td class="num med">'
            f'{sevs.get("MEDIUM", 0)}</td>'
            f'<td class="num low">'
            f'{sevs.get("LOW", 0)}</td>'
            f'</tr>'
        )

    hdr = (
        '<tr><th>CVE</th><th>severity</th><th>score</th>'
        '<th>exploit</th><th>fix</th>'
        '<th>description</th><th>{ctx}</th></tr>'
    )

    # --- CVE details per namespace (collapsible) ---
    ns_sections = []
    for ns in _sorted_ns():
        cves = registry.namespace_cves(ns)
        if not cves:
            continue
        cl = ",".join(sorted(registry.ns_clusters.get(ns, set())))
        rows = []
        for c in cves:
            imgs = sorted(set(
                _short_img(a["image"])
                for a in c.get("affected", [])
                if a.get("namespace") == ns and a.get("image")
            ))
            c_clusters = ",".join(sorted(set(
                a["cluster"]
                for a in c.get("affected", [])
                if a.get("namespace") == ns and a.get("cluster")
            )))
            rows.append(_cve_row(c, _trunc(imgs), c_clusters))

        ns_sections.append(
            f'<div class="section" data-ns="{_h(ns)}"'
            f' data-clusters="{_h(cl)}">'
            f'<h3 id="{_h(ns)}" class="toggle">'
            f'{_h(ns)}'
            f' <span class="count">({len(cves)} CVEs)</span>'
            f' <span class="arrow">+</span>'
            f'</h3>\n'
            f'<div class="collapsible">\n'
            f'<table class="cve-table">\n'
            + hdr.format(ctx="images") + "\n"
            + "\n".join(rows)
            + "\n</table>\n</div>\n</div>"
        )

    # --- CVE details per image (collapsible) ---
    img_sections = []
    for img, sevs in top_imgs:
        cves = registry.image_cves(img)
        if not cves:
            continue
        short = _short_img(img)
        rows = []
        for c in cves:
            nss = sorted(set(
                a["namespace"]
                for a in c.get("affected", [])
                if a.get("image") == img
            ))
            c_clusters = ",".join(sorted(set(
                a["cluster"]
                for a in c.get("affected", [])
                if a.get("image") == img and a.get("cluster")
            )))
            rows.append(_cve_row(c, _trunc(nss), c_clusters))

        img_sections.append(
            f'<div class="section">'
            f'<h3 id="img-{_h(short)}" class="toggle">'
            f'{_h(img)}'
            f' <span class="count">({len(cves)} CVEs)</span>'
            f' <span class="arrow">+</span>'
            f'</h3>\n'
            f'<div class="collapsible">\n'
            f'<table class="cve-table">\n'
            + hdr.format(ctx="namespaces") + "\n"
            + "\n".join(rows)
            + "\n</table>\n</div>\n</div>"
        )

    page = HTML_TEMPLATE.format(
        generated=_now_short(),
        diff_banner=diff_html,
        cards=cards_html,
        cluster_opts=cluster_opts,
        ns_opts=ns_opts,
        nav_clusters=nav_clusters,
        nav_ns=nav_ns,
        ns_rows="\n".join(ns_rows),
        img_rows="\n".join(img_rows),
        ns_sections="\n".join(ns_sections),
        img_sections="\n".join(img_sections),
    )

    (OUTPUT_ROOT / "wiz_report_summary.html").write_text(
        page, encoding="utf-8"
    )
    # also write index.html for nginx default
    (OUTPUT_ROOT / "index.html").write_text(
        page, encoding="utf-8"
    )


HTML_TEMPLATE = """\
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>wiz vulnerability report</title>
<style>
* {{ box-sizing: border-box; }}
body {{
  font-family: system-ui, -apple-system, sans-serif;
  margin: 0; background: #f5f6fa; color: #222;
  display: flex; min-height: 100vh;
}}

/* --- sidebar nav --- */
.sidebar {{
  width: 240px; background: #1e293b; color: #cbd5e1;
  padding: 1em 0; position: fixed; top: 0; left: 0;
  height: 100vh; overflow-y: auto; flex-shrink: 0;
  font-size: 0.82em; z-index: 10;
}}
.sidebar h2 {{
  color: #f1f5f9; font-size: 0.9em; padding: 0.5em 1em;
  margin: 0.8em 0 0.2em; border: none;
  text-transform: uppercase; letter-spacing: 0.05em;
}}
.sidebar ul {{ list-style: none; margin: 0; padding: 0; }}
.sidebar li a {{
  display: block; padding: 4px 1.2em; color: #94a3b8;
  text-decoration: none; white-space: nowrap;
  overflow: hidden; text-overflow: ellipsis;
}}
.sidebar li a:hover,
.sidebar li a.active {{
  background: #334155; color: #e2e8f0;
}}
.sidebar #nav-search {{
  width: calc(100% - 2em); margin: 0 1em 0.5em;
  padding: 6px 8px; border: 1px solid #475569;
  background: #0f172a; color: #e2e8f0;
  border-radius: 4px; font-size: 0.82em;
  outline: none;
}}
.sidebar #nav-search:focus {{ border-color: #3b82f6; }}

/* --- main content --- */
.main {{
  margin-left: 240px; padding: 1.5em 2em; flex: 1;
}}
h1 {{
  font-size: 1.4em; margin: 0 0 0.2em;
}}
h1 + p {{ color: #64748b; font-size: 0.85em; margin: 0 0 1em; }}
h2 {{
  font-size: 1.1em; margin: 1.8em 0 0.5em;
  border-bottom: 2px solid #e2e8f0; padding-bottom: 4px;
}}

/* --- filter bar --- */
.filters {{
  display: flex; gap: 0.8em; align-items: center;
  flex-wrap: wrap; margin: 1em 0; padding: 0.8em 1em;
  background: #fff; border-radius: 8px;
  border: 1px solid #e2e8f0;
}}
.filters label {{ font-size: 0.8em; color: #64748b; }}
.filters select {{
  padding: 4px 8px; border: 1px solid #cbd5e1;
  border-radius: 4px; font-size: 0.85em;
  background: #fff;
}}
.filters .reset {{
  font-size: 0.8em; color: #64748b; cursor: pointer;
  border: none; background: none; text-decoration: underline;
}}

/* --- cards --- */
.cards {{
  display: flex; gap: 0.8em;
  flex-wrap: wrap; margin: 1em 0;
}}
.card {{
  padding: 0.8em 1.2em; border-radius: 8px;
  background: #fff; border: 1px solid #e2e8f0;
  min-width: 100px;
}}
.card .label {{ font-size: 0.75em; color: #64748b; }}
.card .value {{ font-size: 1.6em; font-weight: bold; }}
.card.crit .value {{ color: #dc2626; }}
.card.high .value {{ color: #ea580c; }}
.card.med .value  {{ color: #ca8a04; }}
.card.low .value  {{ color: #2563eb; }}

/* --- diff banner --- */
.diff-banner {{
  padding: 0.7em 1em; margin: 0.8em 0 1em;
  background: #fff; border-radius: 6px;
  border-left: 4px solid #64748b; font-size: 0.9em;
}}
.diff-banner .up   {{ color: #dc2626; font-weight: bold; }}
.diff-banner .down {{ color: #16a34a; font-weight: bold; }}
.diff-banner .flat {{ color: #64748b; }}

/* --- tables --- */
table {{
  border-collapse: collapse; width: 100%;
  margin: 0.5em 0; background: #fff;
  border-radius: 6px; overflow: hidden;
}}
th, td {{
  padding: 6px 10px; border-bottom: 1px solid #f1f5f9;
  text-align: left; font-size: 0.82em;
  vertical-align: top;
}}
th {{
  background: #f8fafc; font-weight: 600;
  white-space: nowrap; position: sticky; top: 0;
}}
.num  {{ text-align: right; }}
.crit {{ color: #dc2626; font-weight: bold; }}
.high {{ color: #ea580c; font-weight: bold; }}
.med  {{ color: #ca8a04; }}
.low  {{ color: #2563eb; }}
.desc {{ max-width: 350px; word-wrap: break-word; color: #64748b; }}
.ctx  {{ max-width: 200px; word-wrap: break-word;
         font-size: 0.8em; color: #64748b; }}
a {{ color: #2563eb; text-decoration: none; }}
a:hover {{ text-decoration: underline; }}

/* --- collapsible sections --- */
.section {{ margin-bottom: 0.5em; }}
h3.toggle {{
  cursor: pointer; font-size: 0.95em;
  margin: 0; padding: 0.6em 0.8em;
  background: #fff; border: 1px solid #e2e8f0;
  border-radius: 6px; display: flex;
  align-items: center; gap: 0.5em;
  user-select: none;
}}
h3.toggle:hover {{ background: #f8fafc; }}
h3.toggle .count {{ color: #94a3b8; font-weight: normal; }}
h3.toggle .arrow {{
  margin-left: auto; font-size: 1.1em;
  color: #94a3b8; transition: transform 0.2s;
}}
h3.toggle.open .arrow {{ transform: rotate(45deg); }}
.collapsible {{
  display: none; padding: 0.5em 0;
}}
.collapsible.open {{ display: block; }}
.hidden {{ display: none !important; }}

/* --- footer --- */
footer {{
  margin-top: 3em; padding-top: 1em;
  border-top: 1px solid #e2e8f0;
  font-size: 0.78em; color: #94a3b8;
}}
</style>
</head>
<body>

<!-- sidebar navigation -->
<nav class="sidebar">
  <input type="text" id="nav-search"
   placeholder="search clusters / namespaces..."
   autocomplete="off" />
  <h2>clusters</h2>
  <ul id="nav-clusters">{nav_clusters}</ul>
  <h2>namespaces</h2>
  <ul id="nav-ns">{nav_ns}</ul>
</nav>

<div class="main">
<h1>wiz kubernetes vulnerability report</h1>
<p>generated {generated}</p>

<!-- filter bar -->
<div class="filters">
  <label>cluster</label>
  <select id="f-cluster">
    <option value="">all clusters</option>
    {cluster_opts}
  </select>
  <label>namespace</label>
  <select id="f-ns">
    <option value="">all namespaces</option>
    {ns_opts}
  </select>
  <label>severity</label>
  <select id="f-sev">
    <option value="">all</option>
    <option value="CRITICAL">critical</option>
    <option value="HIGH">high</option>
    <option value="MEDIUM">medium</option>
    <option value="LOW">low</option>
  </select>
  <button class="reset" onclick="resetFilters()">reset</button>
</div>

<div class="cards">{cards}</div>

{diff_banner}

<h2>by namespace</h2>
<table id="ns-table">
<tr>
  <th>namespace</th><th>unique cves</th>
  <th>images</th><th>critical</th>
  <th>high</th><th>medium</th><th>low</th>
</tr>
{ns_rows}
</table>

<h2>top 20 vulnerable images</h2>
<table>
<tr>
  <th>image</th><th>critical</th>
  <th>high</th><th>medium</th><th>low</th>
</tr>
{img_rows}
</table>

<h2>CVE details by namespace</h2>
<div id="ns-details">{ns_sections}</div>

<h2>CVE details by image</h2>
<div id="img-details">{img_sections}</div>

<footer>
  data from wiz graphsearch api.
  see wiz-report/ for per-namespace json details.
</footer>
</div>

<script>
// --- collapsible toggle ---
document.querySelectorAll('h3.toggle').forEach(h => {{
  h.addEventListener('click', () => {{
    h.classList.toggle('open');
    const c = h.nextElementSibling;
    if (c) c.classList.toggle('open');
  }});
}});

// --- filtering ---
const fCluster = document.getElementById('f-cluster');
const fNs = document.getElementById('f-ns');
const fSev = document.getElementById('f-sev');

function applyFilters() {{
  const cl = fCluster.value;
  const ns = fNs.value;
  const sev = fSev.value;

  // filter namespace summary table rows
  document.querySelectorAll('#ns-table tr[data-ns]').forEach(r => {{
    let show = true;
    if (cl && !(r.dataset.clusters || '').split(',').includes(cl))
      show = false;
    if (ns && r.dataset.ns !== ns) show = false;
    r.classList.toggle('hidden', !show);
  }});

  // filter namespace detail sections
  document.querySelectorAll('#ns-details .section').forEach(s => {{
    let show = true;
    if (cl && !(s.dataset.clusters || '').split(',').includes(cl))
      show = false;
    if (ns && s.dataset.ns !== ns) show = false;
    s.classList.toggle('hidden', !show);

    // filter CVE rows within visible sections by severity
    if (sev && show) {{
      s.querySelectorAll('tr[data-sev]').forEach(r => {{
        r.classList.toggle('hidden', r.dataset.sev !== sev);
      }});
    }} else if (show) {{
      s.querySelectorAll('tr[data-sev]').forEach(r => {{
        r.classList.remove('hidden');
      }});
    }}
  }});

  // filter image detail CVE rows by severity
  document.querySelectorAll('#img-details .section').forEach(s => {{
    if (sev) {{
      let any = false;
      s.querySelectorAll('tr[data-sev]').forEach(r => {{
        const m = r.dataset.sev === sev;
        r.classList.toggle('hidden', !m);
        if (m) any = true;
      }});
      s.classList.toggle('hidden', !any);
    }} else {{
      s.classList.remove('hidden');
      s.querySelectorAll('tr[data-sev]').forEach(r => {{
        r.classList.remove('hidden');
      }});
    }}
  }});
}}

function resetFilters() {{
  fCluster.value = '';
  fNs.value = '';
  fSev.value = '';
  applyFilters();
}}

fCluster.addEventListener('change', applyFilters);
fNs.addEventListener('change', applyFilters);
fSev.addEventListener('change', applyFilters);

// --- sidebar search ---
const navSearch = document.getElementById('nav-search');
navSearch.addEventListener('input', () => {{
  const q = navSearch.value.toLowerCase().trim();
  const filter = (listId) => {{
    document.querySelectorAll('#' + listId + ' li').forEach(li => {{
      const txt = li.textContent.toLowerCase();
      li.style.display = (!q || txt.includes(q)) ? '' : 'none';
    }});
  }};
  filter('nav-clusters');
  filter('nav-ns');
}});

// --- sidebar click scrolls + highlights ---
document.querySelectorAll('.sidebar a.nav-link').forEach(a => {{
  a.addEventListener('click', e => {{
    const href = a.getAttribute('href');
    if (href && href.startsWith('#')) {{
      const target = document.getElementById(href.slice(1));
      if (target) {{
        // expand if collapsed
        if (target.classList.contains('toggle')
            && !target.classList.contains('open')) {{
          target.click();
        }}
        target.scrollIntoView({{ behavior: 'smooth', block: 'start' }});
      }}
    }}
    // set filter if it's a cluster link
    if (a.dataset.cluster) {{
      fCluster.value = a.dataset.cluster;
      applyFilters();
    }}
  }});
}});
</script>
</body>
</html>
"""


# ---------------------
# diff mode - compare against previous run
# ---------------------


def compute_diff(
    registry: CveRegistry,
    prev_summary_path: Path,
) -> dict:
    """compare current CVEs against a previous summary.json.

    returns dict with new_cves, resolved_cves, and severity delta.
    """
    try:
        prev = json.loads(prev_summary_path.read_text())
    except Exception:
        return {"first_run": True}

    prev_ns = prev.get("namespaces", {})
    prev_total = prev.get("total_unique_cves", 0)
    cur_ns = registry.namespace_summary()

    # severity delta
    prev_sev: dict[str, int] = defaultdict(int)
    for s in prev_ns.values():
        for k, v in s.get("by_severity", {}).items():
            prev_sev[k] += v
    cur_sev = registry.sev_totals
    delta = {
        k: cur_sev.get(k, 0) - prev_sev.get(k, 0)
        for k in ("CRITICAL", "HIGH", "MEDIUM", "LOW")
    }

    return {
        "first_run": False,
        "previous_total": prev_total,
        "current_total": registry.total_unique,
        "delta": delta,
        "previous_generated": prev.get("generated", ""),
    }


# ---------------------
# teams webhook
# ---------------------


def post_teams_alert(
    registry: CveRegistry,
    diff: dict,
    webhook_url: str,
):
    """send teams alert if there are new critical/high CVEs."""
    if not webhook_url:
        return

    totals = registry.sev_totals
    crit = totals.get("CRITICAL", 0)
    high = totals.get("HIGH", 0)

    if diff.get("first_run"):
        title = "wiz vulnerability report - initial run"
    else:
        d = diff.get("delta", {})
        if d.get("CRITICAL", 0) <= 0 and d.get("HIGH", 0) <= 0:
            # no increase, skip alert
            return
        title = (
            f"wiz: {d.get('CRITICAL', 0):+d} critical,"
            f" {d.get('HIGH', 0):+d} high"
        )

    payload = {
        "@type": "MessageCard",
        "@context": "http://schema.org/extensions",
        "themeColor": "d32f2f" if crit > 0 else "e65100",
        "summary": title,
        "title": title,
        "sections": [{
            "facts": [
                {"name": "critical", "value": str(crit)},
                {"name": "high", "value": str(high)},
                {"name": "unique CVEs",
                 "value": str(registry.total_unique)},
                {"name": "namespaces",
                 "value": str(len(registry.by_namespace))},
                {"name": "clusters",
                 "value": str(len(registry.by_cluster))},
            ],
        }],
    }
    try:
        requests.post(
            webhook_url,
            json=payload,
            verify=False,
            timeout=30,
        )
        print("  teams alert sent")
    except Exception as e:
        print(f"  teams alert failed: {e}")


# ---------------------
# main
# ---------------------


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="generate wiz vulnerability reports",
    )
    p.add_argument(
        "-c", "--cluster",
        help="filter clusters by name substring"
             " (e.g. -c caas-prod-01)",
    )
    p.add_argument(
        "-n", "--max-clusters",
        type=int,
        help="limit to first N clusters (e.g. -n 1 for quick test)",
    )
    return p.parse_args()


def main():
    args = parse_args()

    client_id = os.getenv("WIZ_CLIENT_ID")
    client_secret = os.getenv("WIZ_CLIENT_SECRET")
    if not client_id or not client_secret:
        raise RuntimeError(
            "set WIZ_CLIENT_ID and WIZ_CLIENT_SECRET in .env"
        )

    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    OUTPUT_DIR.mkdir(exist_ok=True)

    # snapshot previous summary for diff before overwriting
    prev_summary = OUTPUT_DIR / "summary.json"
    diff_input = OUTPUT_ROOT / ".previous_summary.json"
    if prev_summary.exists():
        try:
            diff_input.write_bytes(prev_summary.read_bytes())
        except Exception:
            pass

    print("authenticating...")
    token = get_token(client_id, client_secret)

    print("fetching vulnerabilities...")
    raw_nodes = fetch_all_nodes(
        token,
        cluster_filter=args.cluster,
        max_clusters=args.max_clusters,
    )
    print(f"fetched {len(raw_nodes)} raw findings")

    print("deduplicating...")
    registry = CveRegistry()
    registry.ingest(iter_normalized(raw_nodes))
    print(
        f"  {registry.total_unique} unique CVEs across"
        f" {len(registry.by_namespace)} namespaces"
    )

    # diff against previous run
    diff = compute_diff(registry, diff_input)
    if not diff.get("first_run"):
        d = diff.get("delta", {})
        print(
            f"  diff: {d.get('CRITICAL', 0):+d} crit,"
            f" {d.get('HIGH', 0):+d} high"
            f" vs previous run"
        )

    def _html(r): return export_html(r, diff=diff)

    exports = [
        ("wiz-report/*.json", export_namespace_json),
        ("wiz_report_all_namespaces.csv", export_csv),
        ("wiz-report/summary.json", export_summary_json),
        ("wiz_report_summary.html", _html),
    ]
    for label, fn in exports:
        try:
            fn(registry)
            print(f"  wrote {label}")
        except Exception as e:
            print(f"  error writing {label}: {e}")

    post_teams_alert(registry, diff, TEAMS_WEBHOOK_URL)

    totals = registry.sev_totals
    print(
        f"\ndone - {totals.get('CRITICAL', 0)} critical,"
        f" {totals.get('HIGH', 0)} high"
        f" ({registry.total_unique} unique CVEs)"
    )


if __name__ == "__main__":
    main()
