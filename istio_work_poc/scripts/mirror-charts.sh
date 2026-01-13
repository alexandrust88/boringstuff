#!/bin/bash
set -euo pipefail

# Istio Helm Chart Mirroring Script
# Use this for Phase 2 migration to private Helm/OCI registry

ISTIO_VERSION="${ISTIO_VERSION:-1.28.0}"
TARGET_REGISTRY="${TARGET_REGISTRY:-oci://your-registry.example.com/helm-charts}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

CHARTS=(
    "base"
    "istiod"
    "gateway"
)

# Optional charts
# OPTIONAL_CHARTS=(
#     "cni"
#     "ztunnel"
# )

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

setup_helm_repo() {
    log_info "Adding Istio Helm repository..."
    helm repo add istio https://istio-release.storage.googleapis.com/charts
    helm repo update
}

pull_chart() {
    local chart=$1
    log_info "Pulling chart: $chart version $ISTIO_VERSION"
    helm pull "istio/${chart}" --version "$ISTIO_VERSION" -d "$WORK_DIR"
}

push_to_oci() {
    local chart=$1
    local tgz="${WORK_DIR}/${chart}-${ISTIO_VERSION}.tgz"

    if [[ ! -f "$tgz" ]]; then
        log_warn "Chart package not found: $tgz"
        return 1
    fi

    log_info "Pushing $chart to OCI registry..."
    helm push "$tgz" "$TARGET_REGISTRY"
}

push_to_chartmuseum() {
    local chart=$1
    local chartmuseum_url="${CHARTMUSEUM_URL:-https://chartmuseum.example.com}"
    local tgz="${WORK_DIR}/${chart}-${ISTIO_VERSION}.tgz"

    if [[ ! -f "$tgz" ]]; then
        log_warn "Chart package not found: $tgz"
        return 1
    fi

    log_info "Pushing $chart to ChartMuseum..."
    curl --data-binary "@${tgz}" "${chartmuseum_url}/api/charts"
}

main() {
    echo "========================================"
    echo "Istio Helm Chart Mirroring Script"
    echo "========================================"
    echo "Target: $TARGET_REGISTRY"
    echo "Version: $ISTIO_VERSION"
    echo "========================================"

    if [[ "$TARGET_REGISTRY" == "oci://your-registry.example.com/helm-charts" ]]; then
        log_warn "Please set TARGET_REGISTRY environment variable!"
        log_warn "Example: TARGET_REGISTRY=oci://harbor.mycompany.com/helm-charts $0"
        exit 1
    fi

    setup_helm_repo

    for chart in "${CHARTS[@]}"; do
        pull_chart "$chart"
    done

    log_info "Charts downloaded to: $WORK_DIR"
    ls -la "$WORK_DIR"

    # Push to OCI registry
    for chart in "${CHARTS[@]}"; do
        push_to_oci "$chart"
    done

    log_info "All charts mirrored successfully!"
    log_info ""
    log_info "Update your ArgoCD Applications with:"
    log_info "  repoURL: $TARGET_REGISTRY"
    log_info "  chart: <chart-name>"
    log_info "  targetRevision: \"$ISTIO_VERSION\""
}

main "$@"
