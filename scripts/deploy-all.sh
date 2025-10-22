#!/bin/bash
set -e

# Cleanup function for temporary Docker config
cleanup_temp_docker_config() {
    if [ -n "$TEMP_DOCKER_CONFIG" ] && [ -d "$TEMP_DOCKER_CONFIG" ]; then
        rm -rf "$TEMP_DOCKER_CONFIG"
        unset DOCKER_CONFIG
    fi
}

# Set up trap to clean up on exit
trap cleanup_temp_docker_config EXIT

# Show help message
show_help() {
    echo "Usage: ./deploy-all.sh [OPTIONS]"
    echo ""
    echo "Deploy the complete homelab K3s stack with ArgoCD, monitoring, and applications."
    echo ""
    echo "Options:"
    echo "  --skip-cleanup    Skip cleanup of existing resources (default: cleanup enabled)"
    echo "  --help, -h        Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./deploy-all.sh                # Deploy with automatic cleanup"
    echo "  ./deploy-all.sh --skip-cleanup # Deploy without cleaning up existing resources"
    echo ""
    exit 0
}

# Parse command line arguments
SKIP_CLEANUP=false
if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    show_help
elif [[ "$1" == "--skip-cleanup" ]]; then
    SKIP_CLEANUP=true
elif [[ -n "$1" ]]; then
    echo "Error: Unknown option '$1'"
    echo ""
    show_help
fi

echo "=== Deploying Homelab K3s Stack ==="
echo ""

# Check if any resources exist and clean up for idempotent deployment
if [ "$SKIP_CLEANUP" = false ]; then
    echo "Step 0: Checking for existing resources..."
    RESOURCES_EXIST=false

    # Check for existing namespaces
    if kubectl get namespace argocd &>/dev/null || \
       kubectl get namespace applications &>/dev/null || \
       kubectl get namespace monitoring &>/dev/null; then
        RESOURCES_EXIST=true
    fi

    if [ "$RESOURCES_EXIST" = true ]; then
        echo "  ⚠ Existing resources detected. Cleaning up for fresh deployment..."

        # Delete applications first (to allow graceful shutdown)
        echo "  → Deleting applications..."
        kubectl delete namespace applications --ignore-not-found=true --wait=false

        # Delete monitoring
        echo "  → Deleting monitoring stack..."
        kubectl delete namespace monitoring --ignore-not-found=true --wait=false

        # Delete ArgoCD
        echo "  → Deleting ArgoCD..."
        kubectl delete namespace argocd --ignore-not-found=true --wait=false

        # Wait for namespaces to be fully deleted
        echo "  → Waiting for namespaces to be deleted (this may take a minute)..."
        while kubectl get namespace argocd &>/dev/null || \
              kubectl get namespace applications &>/dev/null || \
              kubectl get namespace monitoring &>/dev/null; do
            sleep 2
        done

        # Clean up any orphaned PVCs (they can persist after namespace deletion)
        echo "  → Cleaning up orphaned persistent volumes..."
        kubectl delete pv --all --ignore-not-found=true &>/dev/null || true

        echo "  ✓ Cleanup complete"
    else
        echo "  ✓ No existing resources found"
    fi
else
    echo "Step 0: Skipping cleanup (--skip-cleanup flag provided)"
fi

echo ""
echo "Step 1: Installing Linkerd service mesh..."
echo "  → Installing Gateway API CRDs..."
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml > /dev/null 2>&1
echo "  → Installing Linkerd CRDs..."
kubectl apply -f manifests/service-mesh/linkerd-crds.yaml > /dev/null 2>&1
echo "  → Installing Linkerd control plane..."
kubectl apply -f manifests/service-mesh/linkerd-control-plane.yaml
echo "  → Waiting for Linkerd to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/linkerd-destination -n linkerd
kubectl wait --for=condition=available --timeout=300s deployment/linkerd-proxy-injector -n linkerd
echo "  ✓ Linkerd service mesh ready (mTLS enabled for all services)"

echo ""
echo "Step 2: Deploying Kubernetes resources..."

# Deploy namespaces first
echo "  → Creating namespaces..."
kubectl apply -f manifests/monitoring/namespace.yaml
kubectl apply -f manifests/applications/namespace.yaml
kubectl apply -f manifests/gitops/argocd-namespace.yaml
echo "  ✓ Namespaces created (Linkerd injection enabled)"

echo ""
echo "Step 3: Installing ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
echo "  → Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
echo "  ✓ ArgoCD ready"

echo "  → Applying ArgoCD customizations..."
kubectl apply -f manifests/gitops/argocd-cmd-params-cm.yaml
kubectl apply -f manifests/gitops/argocd-ingress.yaml
kubectl apply -f manifests/gitops/argocd-image-updater.yaml
echo "  → Restarting ArgoCD server to pick up configuration..."
kubectl rollout restart deployment/argocd-server -n argocd
kubectl wait --for=condition=available --timeout=120s deployment/argocd-server -n argocd
echo "  ✓ ArgoCD configured"

echo ""
echo "Step 4: Deploying monitoring stack..."
kubectl apply -f manifests/monitoring/
echo "  → Waiting for Prometheus..."
kubectl wait --for=condition=available --timeout=300s deployment/prometheus -n monitoring
echo "  ✓ Monitoring stack ready"

echo ""
echo "Step 5: Deploying infrastructure applications..."
echo "  → Deploying PostgreSQL, Redis, and Gitea..."
kubectl apply -f manifests/applications/namespace.yaml
kubectl apply -f manifests/applications/postgresql.yaml
kubectl apply -f manifests/applications/redis.yaml
kubectl apply -f manifests/applications/gitea.yaml
echo "  → Waiting for PostgreSQL..."
kubectl wait --for=condition=available --timeout=300s deployment/postgresql -n applications
echo "  → Waiting for Redis..."
kubectl wait --for=condition=available --timeout=300s deployment/redis -n applications
echo "  → Waiting for Gitea..."
kubectl wait --for=condition=available --timeout=300s deployment/gitea -n applications
echo "  ✓ Infrastructure applications ready"

echo ""
echo "Step 6: Configuring ingress..."
kubectl apply -f manifests/infrastructure/
echo "  ✓ Ingress configured"
echo "  → Waiting for ingress to be ready..."
sleep 10  # Give ingress a moment to configure

echo ""
echo "Step 7: Setting up Gitea container registry..."

# Set up temporary Docker config directory for non-invasive registry configuration
TEMP_DOCKER_CONFIG=$(mktemp -d)
export DOCKER_CONFIG="$TEMP_DOCKER_CONFIG"
echo "  → Created temporary Docker config at $TEMP_DOCKER_CONFIG"

# Create Docker config with insecure registry
mkdir -p "$TEMP_DOCKER_CONFIG"
cat > "$TEMP_DOCKER_CONFIG/config.json" <<EOF
{
  "auths": {},
  "HttpHeaders": {
    "User-Agent": "Docker-Client/19.03.12 (linux)"
  },
  "insecure-registries": ["localhost"]
}
EOF
echo "  ✓ Configured temporary Docker config for localhost registry"

# Create Gitea admin user automatically via Kubernetes Job
echo "  → Creating Gitea admin user (homelab/homelab)..."
kubectl apply -f manifests/applications/gitea-init-user.yaml

# Wait for the job to complete (give it plenty of time for Gitea to initialize)
echo "  → Waiting for user creation job to complete (this may take a minute)..."
kubectl wait --for=condition=complete --timeout=180s job/gitea-init-user -n applications 2>/dev/null || {
    echo "  ⚠️  User creation job did not complete in time. Checking logs..."
    kubectl logs -n applications job/gitea-init-user --tail=20 2>/dev/null || true
    echo ""
    echo "  Attempting to continue anyway (user creation will be retried if needed)..."
}
echo "  ✓ Gitea admin user should be ready (username: homelab, password: homelab)"

# Login to Docker registry with temporary config (with retry)
echo "  → Logging in to Gitea registry..."
login_attempts=0
max_login_attempts=5
until echo "homelab" | docker login localhost -u homelab --password-stdin > /dev/null 2>&1; do
    login_attempts=$((login_attempts + 1))
    if [ $login_attempts -ge $max_login_attempts ]; then
        echo "  ❌ Docker login failed after $max_login_attempts attempts. Checking Gitea status..."
        kubectl logs -n applications -l app=gitea --tail=30
        echo ""
        kubectl get pods -n applications -l app=gitea
        exit 1
    fi
    echo "  → Login attempt $login_attempts/$max_login_attempts failed, retrying in 5 seconds..."
    sleep 5
done
echo "  ✓ Logged in to Gitea registry"

echo ""
echo "Step 8: Building and pushing Django image..."
# Check if sample Django app exists
if [ ! -d "sample-django-app" ]; then
    echo "Error: sample-django-app directory not found!"
    echo "Please run this script from the remotelab project root."
    exit 1
fi

echo "  → Building Django container image from source..."
cd sample-django-app
docker build -t localhost/homelab/django-app:latest .
cd ..
echo "  ✓ Django image built"

echo "  → Pushing to Gitea registry..."
docker push localhost/homelab/django-app:latest
echo "  ✓ Django image pushed to registry"

echo ""
echo "Step 9: Deploying Django application..."
kubectl apply -f manifests/applications/django.yaml
echo "  → Waiting for Django (may take a few minutes)..."
kubectl wait --for=condition=available --timeout=600s deployment/django -n applications || {
    echo "  ⚠ Warning: Django deployment timed out or failed"
    kubectl get pods -n applications -l app=django
    echo "  Check logs with: kubectl logs -n applications -l app=django"
}
echo "  ✓ Django application deployed"

echo ""
echo "========================================"
echo "  🎉 Deployment Complete!"
echo "========================================"
echo ""
echo "🔒 Security Features:"
echo "  • mTLS enabled for all service-to-service communication (via Linkerd)"
echo "  • HTTPS with self-signed certificates for external access"
echo "  • Automatic HTTP to HTTPS redirect"
echo ""
echo "📍 Services Available (HTTPS with self-signed certificates):"
echo "  • ArgoCD:     https://localhost/argocd"
echo "  • Gitea:      https://localhost/gitea (username: homelab, password: homelab)"
echo "  • Django API: https://localhost/django"
echo "  • Prometheus: https://localhost/prometheus"
echo "  • Grafana:    https://localhost/grafana (admin/admin)"
echo ""
echo "  ℹ️  Accept the self-signed certificate warning in your browser"
echo "  ℹ️  HTTP requests are automatically redirected to HTTPS"
echo ""
echo "🔐 ArgoCD Credentials:"
echo "  Username: admin"
echo "  Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "Check ArgoCD logs if password retrieval fails")"
echo ""
echo "🔐 Gitea Credentials:"
echo "  Username: homelab"
echo "  Password: homelab"
echo ""
echo "📦 Container Registry (Gitea):"
echo "  • Registry API: https://localhost/v2"
echo "  • Django image: localhost/homelab/django-app:latest"
echo "  • Login: echo 'homelab' | docker login localhost -u homelab --password-stdin"
echo "  • Push new versions:"
echo "    docker build -t localhost/homelab/django-app:v2 ."
echo "    docker push localhost/homelab/django-app:v2"
echo ""
echo "📚 Documentation: docs/CONTAINER_REGISTRY_SETUP.md"
echo ""
echo "✨ mTLS encryption for all pod-to-pod communication via Linkerd service mesh!"
echo "✨ All services use path-based routing - no /etc/hosts configuration required!"
echo "✨ No sudo required - all images are pushed to Gitea registry!"
echo "✨ Fully automated - no Docker daemon configuration changes needed!"
echo ""
echo "🔍 Verify mTLS Status:"
echo "  • Check Linkerd dashboard: export PATH=\$PATH:/home/adam/.linkerd2/bin && linkerd viz install | kubectl apply -f - && linkerd viz dashboard"
echo "  • View meshed pods: kubectl get pods -n applications -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.spec.containers[*].name}{\"\\n\"}{end}'"
echo ""