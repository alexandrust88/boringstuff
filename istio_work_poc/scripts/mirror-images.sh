#!/bin/bash
set -euo pipefail

# Istio Image Mirroring Script
# Use this for Phase 2 migration to private registry

ISTIO_VERSION="${ISTIO_VERSION:-1.28.0}"
SOURCE_REGISTRY="${SOURCE_REGISTRY:-docker.io/istio}"
TARGET_REGISTRY="${TARGET_REGISTRY:-your-registry.example.com/istio}"

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

# Core Istio images
IMAGES=(
    "pilot"
    "proxyv2"
)

# Optional images (uncomment if needed)
# OPTIONAL_IMAGES=(
#     "ztunnel"       # For ambient mode
#     "install-cni"   # For CNI plugin
# )

mirror_image() {
    local img=$1
    local src="${SOURCE_REGISTRY}/${img}:${ISTIO_VERSION}"
    local dst="${TARGET_REGISTRY}/${img}:${ISTIO_VERSION}"

    log_info "Pulling: $src"
    docker pull "$src"

    log_info "Tagging: $dst"
    docker tag "$src" "$dst"

    log_info "Pushing: $dst"
    docker push "$dst"

    log_info "Successfully mirrored: $img"
}

main() {
    echo "========================================"
    echo "Istio Image Mirroring Script"
    echo "========================================"
    echo "Source: $SOURCE_REGISTRY"
    echo "Target: $TARGET_REGISTRY"
    echo "Version: $ISTIO_VERSION"
    echo "========================================"

    if [[ "$TARGET_REGISTRY" == "your-registry.example.com/istio" ]]; then
        log_warn "Please set TARGET_REGISTRY environment variable!"
        log_warn "Example: TARGET_REGISTRY=harbor.mycompany.com/istio $0"
        exit 1
    fi

    for img in "${IMAGES[@]}"; do
        mirror_image "$img"
    done

    log_info "All images mirrored successfully!"
    log_info ""
    log_info "Update your Helm values with:"
    log_info "  global:"
    log_info "    hub: $TARGET_REGISTRY"
    log_info "    tag: \"$ISTIO_VERSION\""
}

main "$@"
