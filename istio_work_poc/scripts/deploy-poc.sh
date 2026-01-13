#!/bin/bash
set -euo pipefail

# Istio 1.28 ArgoCD POC Deployment Script
# This script bootstraps the ArgoCD App-of-Apps for Istio

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed"
        exit 1
    fi

    if ! command -v argocd &> /dev/null; then
        log_warn "argocd CLI not installed (optional but recommended)"
    fi

    # Check cluster connection
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    # Check if ArgoCD is installed
    if ! kubectl get namespace argocd &> /dev/null; then
        log_error "ArgoCD namespace not found. Please install ArgoCD first."
        log_info "Install ArgoCD with: kubectl create namespace argocd && kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
        exit 1
    fi

    log_info "Prerequisites check passed!"
}

# Create namespaces
create_namespaces() {
    log_info "Creating Istio namespaces..."
    kubectl apply -f "$PROJECT_ROOT/base/namespace.yaml"
}

# Apply ArgoCD Project
apply_project() {
    log_info "Creating ArgoCD Project for Istio..."
    kubectl apply -f "$PROJECT_ROOT/argocd/project/istio-project.yaml"
}

# Apply Root Application (App-of-Apps)
apply_root_app() {
    log_info "Deploying root App-of-Apps..."
    kubectl apply -f "$PROJECT_ROOT/argocd/apps/root-app.yaml"
}

# Apply individual apps (alternative to App-of-Apps)
apply_individual_apps() {
    log_info "Deploying Istio applications individually..."

    log_info "Applying istio-base..."
    kubectl apply -f "$PROJECT_ROOT/argocd/apps/istio-base-app.yaml"

    log_info "Waiting for CRDs to be ready..."
    sleep 30

    log_info "Applying istiod..."
    kubectl apply -f "$PROJECT_ROOT/argocd/apps/istiod-app.yaml"

    log_info "Waiting for istiod to be ready..."
    sleep 60

    log_info "Applying istio-gateway..."
    kubectl apply -f "$PROJECT_ROOT/argocd/apps/istio-gateway-app.yaml"
}

# Verify deployment
verify_deployment() {
    log_info "Verifying deployment..."

    log_info "ArgoCD Applications:"
    kubectl get applications -n argocd | grep -E "istio|NAME"

    log_info "Istio System pods:"
    kubectl get pods -n istio-system 2>/dev/null || log_warn "No pods in istio-system yet"

    log_info "Istio Ingress pods:"
    kubectl get pods -n istio-ingress 2>/dev/null || log_warn "No pods in istio-ingress yet"
}

# Main
main() {
    echo "========================================"
    echo "Istio 1.28 ArgoCD POC Deployment"
    echo "========================================"

    check_prerequisites
    create_namespaces
    apply_project

    # Choose deployment method
    if [[ "${1:-app-of-apps}" == "individual" ]]; then
        apply_individual_apps
    else
        apply_root_app
    fi

    verify_deployment

    log_info "Deployment initiated!"
    log_info "Monitor progress with: argocd app list"
    log_info "Or: kubectl get applications -n argocd -w"
}

main "$@"
