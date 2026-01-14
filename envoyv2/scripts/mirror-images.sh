#!/bin/bash
set -euo pipefail

# Envoy Gateway Image Mirroring Script
# Use this for Phase 2 migration to private registry

EG_VERSION="${EG_VERSION:-v1.3.0}"
ENVOY_VERSION="${ENVOY_VERSION:-distroless-v1.32.0}"
SOURCE_REGISTRY="${SOURCE_REGISTRY:-docker.io/envoyproxy}"
TARGET_REGISTRY="${TARGET_REGISTRY:-your-registry.example.com/envoyproxy}"

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

# Images to mirror
IMAGES=(
    "gateway:${EG_VERSION}"
    "envoy:${ENVOY_VERSION}"
)

# Optional images
# OPTIONAL_IMAGES=(
#     "ratelimit:latest"
# )

mirror_image() {
    local img=$1
    local src="${SOURCE_REGISTRY}/${img}"
    local dst="${TARGET_REGISTRY}/${img}"

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
    echo "Envoy Gateway Image Mirroring Script"
    echo "========================================"
    echo "Source: $SOURCE_REGISTRY"
    echo "Target: $TARGET_REGISTRY"
    echo "Gateway Version: $EG_VERSION"
    echo "Envoy Version: $ENVOY_VERSION"
    echo "========================================"

    if [[ "$TARGET_REGISTRY" == "your-registry.example.com/envoyproxy" ]]; then
        log_warn "Please set TARGET_REGISTRY environment variable!"
        log_warn "Example: TARGET_REGISTRY=harbor.mycompany.com/envoyproxy $0"
        exit 1
    fi

    for img in "${IMAGES[@]}"; do
        mirror_image "$img"
    done

    log_info "All images mirrored successfully!"
    log_info ""
    log_info "Update your Helm values with:"
    log_info "  deployment:"
    log_info "    envoyGateway:"
    log_info "      image:"
    log_info "        repository: ${TARGET_REGISTRY}/gateway"
    log_info "        tag: \"${EG_VERSION}\""
}

main "$@"
