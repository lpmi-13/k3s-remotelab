#!/bin/bash

set -e

# K3s Homelab Installation Script
# Installs k3s with optimal configuration for homelab use

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
K3S_VERSION=${K3S_VERSION:-"v1.28.5+k3s1"}
NODE_IP=${NODE_IP:-$(ip route get 1 | awk '{print $7; exit}')}
CLUSTER_DOMAIN=${CLUSTER_DOMAIN:-"homelab.local"}

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

check_prerequisites() {
    log "Checking prerequisites..."

    # Check if running as root or with sudo
    if [[ $EUID -eq 0 ]]; then
        warning "Running as root. This is not recommended for production."
    fi

    # Check system resources
    RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $RAM_GB -lt 4 ]]; then
        warning "Less than 4GB RAM detected. Performance may be degraded."
    fi

    # Check available disk space
    DISK_GB=$(df / | awk 'NR==2{print int($4/1024/1024)}')
    if [[ $DISK_GB -lt 20 ]]; then
        warning "Less than 20GB disk space available. Monitor usage carefully."
    fi

    # Check for existing k3s installation
    if command -v k3s &> /dev/null; then
        warning "K3s is already installed. This script will reinstall it."
        read -p "Continue? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
        uninstall_k3s
    fi

    success "Prerequisites check completed"
}

uninstall_k3s() {
    log "Uninstalling existing k3s..."
    if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
        sudo /usr/local/bin/k3s-uninstall.sh
    fi
}

install_k3s() {
    log "Installing k3s ${K3S_VERSION}..."

    # Prepare k3s configuration
    sudo mkdir -p /etc/rancher/k3s

    # Create k3s config file
    cat <<EOF | sudo tee /etc/rancher/k3s/config.yaml
# K3s configuration for homelab
cluster-domain: ${CLUSTER_DOMAIN}
disable:
  - servicelb  # We'll use Traefik LoadBalancer
  - metrics-server  # We'll use our own monitoring
node-ip: ${NODE_IP}
cluster-init: true
write-kubeconfig-mode: "0644"
kube-apiserver-arg:
  - "feature-gates=GracefulNodeShutdown=true"
kube-controller-manager-arg:
  - "feature-gates=GracefulNodeShutdown=true"
kubelet-arg:
  - "feature-gates=GracefulNodeShutdown=true"
  - "graceful-node-shutdown=true"
  - "graceful-node-shutdown-grace-period=30s"
  - "graceful-node-shutdown-grace-period-critical-pods=10s"
EOF

    # Install k3s
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${K3S_VERSION} sh -s - server

    # Wait for k3s to be ready
    log "Waiting for k3s to be ready..."
    while ! sudo k3s kubectl get nodes &> /dev/null; do
        sleep 2
    done

    success "k3s installed successfully"
}

configure_kubectl() {
    log "Configuring kubectl access..."

    # Create .kube directory if it doesn't exist
    mkdir -p ~/.kube

    # Copy k3s kubeconfig
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $(id -u):$(id -g) ~/.kube/config

    # Verify kubectl access
    if kubectl get nodes &> /dev/null; then
        success "kubectl configured successfully"
    else
        error "Failed to configure kubectl"
    fi
}

install_helm() {
    log "Installing Helm..."

    if command -v helm &> /dev/null; then
        warning "Helm is already installed"
        return
    fi

    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    success "Helm installed successfully"
}

setup_storage() {
    log "Configuring storage..."

    # Wait for local-path storage class to be available
    while ! kubectl get storageclass local-path &> /dev/null; do
        log "Waiting for local-path storage class..."
        sleep 5
    done

    # Set local-path as default storage class
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

    success "Storage configured successfully"
}

configure_traefik() {
    log "Configuring Traefik ingress..."

    # Wait for Traefik to be ready
    while ! kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik &> /dev/null; do
        log "Waiting for Traefik to be ready..."
        sleep 5
    done

    # Create middleware for common headers
    kubectl apply -f - <<EOF
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: default-headers
  namespace: kube-system
spec:
  headers:
    browserXssFilter: true
    contentTypeNosniff: true
    forceSTSHeader: true
    stsIncludeSubdomains: true
    stsPreload: true
    stsSeconds: 31536000
    customFrameOptionsValue: SAMEORIGIN
    customRequestHeaders:
      X-Forwarded-Proto: https
EOF

    success "Traefik configured successfully"
}

create_namespaces() {
    log "Creating namespaces..."

    kubectl apply -f "${PROJECT_ROOT}/manifests/namespaces/"

    success "Namespaces created successfully"
}

display_info() {
    log "Installation completed!"
    echo
    echo "Cluster Information:"
    echo "  Node IP: ${NODE_IP}"
    echo "  Cluster Domain: ${CLUSTER_DOMAIN}"
    echo "  Kubeconfig: ~/.kube/config"
    echo
    echo "Next Steps:"
    echo "  1. Run: kubectl get nodes"
    echo "  2. Deploy the stack: ./scripts/deploy-all.sh"
    echo "  3. Access services at http://localhost/<service-name>"
    echo
    echo "Useful Commands:"
    echo "  kubectl get pods -A"
    echo "  kubectl get ingress -A"
    echo "  k3s kubectl ..."
    echo
}

main() {
    log "Starting k3s homelab installation..."

    check_prerequisites
    install_k3s
    configure_kubectl
    install_helm
    setup_storage
    configure_traefik
    create_namespaces

    display_info
    success "k3s homelab installation completed successfully!"
}

# Run main function
main "$@"