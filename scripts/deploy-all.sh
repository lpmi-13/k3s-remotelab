#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/platform.sh"

# Show help message
show_help() {
    echo "Usage: ./deploy-all.sh [OPTIONS]"
    echo ""
    echo "Deploy the complete remotelab K3s stack with ArgoCD, monitoring, and applications."
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

echo "=== Deploying Remotelab K3s Stack ==="
echo ""

# Switch to local cluster context
echo "Ensuring kubectl is configured for local cluster..."
switch_to_local_context || {
    echo "Warning: Could not switch to local cluster context. Continuing with current context."
    echo "Current context: $(kubectl config current-context 2>/dev/null || echo 'none')"
}
echo ""

# Function to forcefully clean up a namespace by removing finalizers
# This function ensures namespaces can always be deleted, even when stuck in Terminating state.
# It handles:
#   - Non-existent namespaces (no-op, returns success)
#   - ArgoCD applications with finalizers (removes them before namespace deletion)
#   - Any resource with finalizers that blocks namespace deletion
#   - Namespaces stuck in Terminating state (patches namespace itself)
#   - Timeout scenarios with final forced cleanup via API
# Returns: 0 on success, 1 if manual intervention is needed (rare)
force_delete_namespace() {
    local namespace=$1
    local max_wait=60
    local waited=0

    # Check if namespace exists
    if ! kubectl get namespace "$namespace" &>/dev/null; then
        return 0
    fi

    echo "  → Processing namespace: $namespace"

    # First, remove finalizers from all ArgoCD applications if in argocd namespace
    if [ "$namespace" = "argocd" ]; then
        echo "    • Removing finalizers from ArgoCD applications..."
        kubectl get applications.argoproj.io -n argocd -o name 2>/dev/null | \
            xargs -I {} kubectl patch {} -n argocd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    fi

    # Remove finalizers from common resources that block namespace deletion
    echo "    • Removing finalizers from resources in $namespace..."

    # Remove finalizers from all resources with finalizers in the namespace
    for resource_type in $(kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null | grep -v "events" || true); do
        kubectl get "$resource_type" -n "$namespace" -o name 2>/dev/null | \
            xargs -I {} kubectl patch {} -n "$namespace" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    done

    # Delete the namespace (or it may already be deleting)
    echo "    • Deleting namespace $namespace..."
    kubectl delete namespace "$namespace" --ignore-not-found=true --wait=false 2>/dev/null || true

    # Check if namespace is stuck in Terminating state
    sleep 2
    if kubectl get namespace "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Terminating"; then
        echo "    • Namespace stuck in Terminating state, forcing cleanup..."

        # Remove finalizers from the namespace itself
        kubectl patch namespace "$namespace" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true

        # Try to remove spec.finalizers if they exist
        kubectl patch namespace "$namespace" -p '{"spec":{"finalizers":null}}' --type=merge 2>/dev/null || true
    fi

    # Wait for namespace to be fully deleted
    echo "    • Waiting for namespace deletion..."
    while kubectl get namespace "$namespace" &>/dev/null; do
        if [ $waited -ge $max_wait ]; then
            echo "    ⚠ Warning: Namespace $namespace still exists after ${max_wait}s"
            echo "    • Attempting final forced cleanup..."

            # Last resort: try to delete the namespace by removing all finalizers via API
            kubectl get namespace "$namespace" -o json 2>/dev/null | \
                jq '.spec.finalizers = [] | .metadata.finalizers = []' | \
                kubectl replace --raw "/api/v1/namespaces/$namespace/finalize" -f - 2>/dev/null || true

            sleep 5
            if kubectl get namespace "$namespace" &>/dev/null; then
                echo "    ⚠ Warning: Could not force delete namespace $namespace"
                echo "    • Manual intervention may be required"
                return 1
            fi
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    echo "    ✓ Namespace $namespace deleted"
    return 0
}

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

        # Delete initialization jobs first (they may hold references)
        echo "  → Deleting initialization jobs..."
        kubectl delete job gitea-init-user -n applications --ignore-not-found=true --wait=false 2>/dev/null || true
        kubectl delete job gitea-init-repo -n applications --ignore-not-found=true --wait=false 2>/dev/null || true
        kubectl delete job gitea-init-manifests -n applications --ignore-not-found=true --wait=false 2>/dev/null || true

        # Explicitly delete PVCs to trigger storage cleanup
        echo "  → Deleting PVCs to cleanup persistent storage..."
        kubectl delete pvc gitea-pvc -n applications --ignore-not-found=true --wait=true --timeout=30s 2>/dev/null || true
        kubectl delete pvc postgres-pvc -n applications --ignore-not-found=true --wait=true --timeout=30s 2>/dev/null || true
        kubectl delete pvc redis-data -n applications --ignore-not-found=true --wait=true --timeout=30s 2>/dev/null || true
        sleep 3  # Give local-path-provisioner time to cleanup storage directories

        # Force delete namespaces with finalizer removal
        echo "  → Force deleting namespaces (removing finalizers)..."

        # Delete in reverse order of dependencies
        force_delete_namespace "applications"
        force_delete_namespace "monitoring"
        force_delete_namespace "argocd"

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
kubectl apply --server-side --force-conflicts -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml > /dev/null 2>&1

# Check if linkerd CLI is available and add to PATH
if ! command -v linkerd &> /dev/null; then
    LINKERD_PATH=$(get_linkerd_path)
    if [[ -f "${LINKERD_PATH}/linkerd" ]]; then
        export PATH=$PATH:${LINKERD_PATH}
    fi
fi

# Check if Linkerd is already installed
if kubectl get namespace linkerd > /dev/null 2>&1 && kubectl get configmap linkerd-config -n linkerd > /dev/null 2>&1; then
    echo "  → Linkerd already installed, performing upgrade..."
    echo "  → Upgrading Linkerd CRDs..."
    linkerd upgrade --crds | kubectl apply -f - > /dev/null 2>&1
    echo "  → Upgrading Linkerd control plane with fresh certificates (7-day validity)..."
    linkerd upgrade --identity-issuance-lifetime=168h0m0s | kubectl apply -f -
else
    echo "  → Performing fresh Linkerd installation..."
    echo "  → Installing Linkerd CRDs..."
    linkerd install --crds | kubectl apply -f - > /dev/null 2>&1
    echo "  → Installing Linkerd control plane with fresh certificates (7-day validity)..."
    linkerd install --identity-issuance-lifetime=168h0m0s | kubectl apply -f -
fi

echo "  → Waiting for Linkerd to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/linkerd-destination -n linkerd
kubectl wait --for=condition=available --timeout=300s deployment/linkerd-proxy-injector -n linkerd
echo "  ✓ Linkerd service mesh ready (mTLS enabled for all services, certificates valid for 7 days)"

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
echo "  → Patching ArgoCD server for subpath support..."
kubectl patch deployment argocd-server -n argocd --type='strategic' --patch-file manifests/gitops/argocd-server-patch.yaml
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
echo "  → Creating Gitea registry secret..."
kubectl apply -f manifests/applications/gitea-registry-secret.yaml
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
echo "Step 7: Setting up Gitea and container registry..."

# Create Gitea admin user automatically via Kubernetes Job
echo "  → Creating Gitea admin user (remotelab/remotelab)..."
kubectl apply -f manifests/applications/gitea-init-user.yaml

# Wait for the job to complete (give it plenty of time for Gitea to initialize)
echo "  → Waiting for user creation job to complete (this may take a minute)..."
kubectl wait --for=condition=complete --timeout=180s job/gitea-init-user -n applications 2>/dev/null || {
    echo "  ⚠️  User creation job did not complete in time. Checking logs..."
    kubectl logs -n applications job/gitea-init-user --tail=20 2>/dev/null || true
    echo ""
    echo "  Attempting to continue anyway (user creation will be retried if needed)..."
}
echo "  ✓ Gitea admin user ready (username: remotelab, password: remotelab)"

echo ""
echo "Step 8: Generating Gitea Actions runner token..."
echo "  → Waiting for Gitea to be fully initialized..."
sleep 10

echo "  → Generating runner token from Gitea CLI..."
NEW_TOKEN=$(kubectl exec -n applications deployment/gitea -c gitea -- su -c "/usr/local/bin/gitea actions generate-runner-token" git 2>&1 | grep -v "level=" | tail -1)

if [ -z "$NEW_TOKEN" ]; then
    echo "  ❌ Error: Failed to generate runner token"
    echo "  Check Gitea logs with: kubectl logs -n applications deployment/gitea"
    exit 1
fi

echo "  ✓ Generated token: ${NEW_TOKEN:0:20}..."

echo ""
echo "Step 9: Deploying Gitea Actions runner..."
echo "  → Deploying Gitea Actions runner..."
kubectl apply -f manifests/applications/gitea-actions-runner.yaml

echo "  → Waiting for runner deployment to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/act-runner -n applications 2>/dev/null || {
    echo "  ⚠️  Runner deployment taking longer than expected..."
    kubectl get pods -n applications -l app=act-runner
}

# Patch the secret AFTER the manifest is applied (so we overwrite the static placeholder)
echo "  → Updating runner-secret with dynamic token..."
kubectl patch secret -n applications runner-secret -p "{\"stringData\":{\"token\":\"$NEW_TOKEN\"}}"
echo "  ✓ Runner token configured"

# Restart the runner pod to pick up the new token
echo "  → Restarting runner to pick up new token..."
kubectl delete pod -n applications -l app=act-runner --ignore-not-found=true 2>/dev/null || true
sleep 5
kubectl wait --for=condition=ready --timeout=60s pod -l app=act-runner -n applications 2>/dev/null || {
    echo "  ⚠️  Runner pod taking longer than expected to restart..."
    kubectl get pods -n applications -l app=act-runner
}
echo "  ✓ Gitea Actions runner deployed and registered"

echo ""
echo "Step 10: Initializing repositories in Gitea..."

# Delete old repository initialization jobs if they exist (for idempotency)
kubectl delete job gitea-init-repo -n applications --ignore-not-found=true 2>/dev/null || true
kubectl delete job gitea-init-manifests -n applications --ignore-not-found=true 2>/dev/null || true
sleep 2

echo "  → Creating manifests repository..."
kubectl apply -f manifests/applications/gitea-init-manifests.yaml

echo "  → Creating Django app repository..."
kubectl apply -f manifests/applications/gitea-init-repo.yaml

echo "  → Waiting for manifests repository initialization (this may take a minute)..."
kubectl wait --for=condition=complete --timeout=180s job/gitea-init-manifests -n applications 2>/dev/null || {
    echo "  ⚠️  Manifests repository initialization did not complete in time. Checking logs..."
    kubectl logs -n applications job/gitea-init-manifests --tail=40 2>/dev/null || true
    echo ""
    echo "  ❌ Failed to initialize manifests repository. Cannot proceed without ArgoCD source."
    exit 1
}
echo "  ✓ Manifests repository initialized in Gitea"

echo "  → Waiting for Django app repository initialization (this may take a minute)..."
kubectl wait --for=condition=complete --timeout=180s job/gitea-init-repo -n applications 2>/dev/null || {
    echo "  ⚠️  Django app repository initialization did not complete in time. Checking logs..."
    kubectl logs -n applications job/gitea-init-repo --tail=40 2>/dev/null || true
    echo ""
    echo "  ❌ Failed to initialize Django app repository. Cannot proceed without Django image."
    exit 1
}
echo "  ✓ Django app repository initialized in Gitea"

# Extract the API token from the job logs and create a secret for workflow
echo "  → Configuring repository secrets for workflow..."
API_TOKEN=$(kubectl logs -n applications job/gitea-init-repo 2>/dev/null | grep "API_TOKEN=" | tail -1 | cut -d'=' -f2)

if [ -n "$API_TOKEN" ]; then
    echo "  ✓ API token obtained"
    # Create a secret that can be used by Gitea Actions
    # Note: Gitea Actions uses secrets configured via the web UI or API
    # For now, we'll use the remotelab user credentials which have registry access
    echo "  → Token will be available for manual configuration if needed"
else
    echo "  ⚠️  Warning: Could not extract API token. Workflow will use actor credentials."
fi

echo ""
echo "Step 11: Deploying Django application..."
echo "  → Initial deployment uses ghcr.io/lpmi-13/k3s-remotelab-django:latest"
echo "  → After runner is working and workflow runs, ArgoCD Image Updater will switch to Gitea registry"
kubectl apply -k manifests/applications/django/overlays/production

echo ""
echo "Step 12: Verifying Django deployment..."
echo "  → Waiting for Django (may take a few minutes)..."
kubectl wait --for=condition=available --timeout=600s deployment/django -n applications || {
    echo "  ⚠ Warning: Django deployment timed out or failed"
    kubectl get pods -n applications -l app=django
    echo "  Check logs with: kubectl logs -n applications -l app=django"
}
echo "  ✓ Django application deployed"

echo ""
echo "Step 13: Deploying ArgoCD Applications..."
echo "  → Deploying ArgoCD applications from local manifests..."
kubectl apply -f argocd-apps/

echo "  → Waiting for ArgoCD applications to be created..."
sleep 5

echo "  → Patching root-app to ensure it uses correct repository URL..."
# Ensure root-app uses the internal service URL and has directory recurse enabled
kubectl patch application root-app -n argocd --type merge -p '{"spec":{"source":{"repoURL":"http://gitea.applications.svc.cluster.local:3000/remotelab/manifests.git","directory":{"recurse":true}}}}'

echo "  → Waiting for root-app to sync..."
sleep 10

echo "  → Checking ArgoCD application status..."
kubectl get applications -n argocd || {
    echo "  ⚠ Warning: Could not list ArgoCD applications"
}
echo "  ✓ ArgoCD applications deployed"

echo "  → Note: ArgoCD applications will now sync from Gitea repository"
echo "  → ArgoCD will manage future updates automatically"

echo ""
echo "========================================"
echo "  Deployment Complete!"
echo "========================================"
echo ""
echo "Security Features:"
echo "  - mTLS enabled for all service-to-service communication (via Linkerd)"
echo "  - HTTPS with self-signed certificates for external access"
echo "  - Automatic HTTP to HTTPS redirect"
echo ""
echo "Services Available (HTTPS with self-signed certificates):"
echo "  - ArgoCD:     https://localhost/argocd"
echo "  - Gitea:      https://localhost/gitea (username: remotelab, password: remotelab)"
echo "  - Django API: https://localhost/django"
echo "  - Prometheus: https://localhost/prometheus"
echo "  - Grafana:    https://localhost/grafana (admin/admin)"
echo ""
echo "  Note: Accept the self-signed certificate warning in your browser"
echo "  Note: HTTP requests are automatically redirected to HTTPS"
echo ""
echo "ArgoCD Credentials:"
echo "  Username: admin"
echo "  Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "Check ArgoCD logs if password retrieval fails")"
echo ""
echo "Gitea Credentials:"
echo "  Username: remotelab"
echo "  Password: remotelab"
echo ""
echo "Container Registry (Gitea):"
echo "  - Registry: gitea:3000"
echo "  - Django image: gitea:3000/remotelab/django-app:1.0.1"
echo "  - Repository: https://localhost/gitea/remotelab/django-app"
echo ""
echo "GitOps Configuration:"
echo "  - Manifests repository: https://localhost/gitea/remotelab/manifests"
echo "  - ArgoCD is configured to sync from Gitea"
echo "  - View applications: https://localhost/argocd"
echo "  - Check sync status: kubectl get applications -n argocd"
echo ""
echo "CI/CD Pipeline (Gitea Actions):"
echo "  - Django app repository created with automated image pull/push workflow"
echo "  - Push to main branch triggers automatic image pull from ghcr.io and push to Gitea registry"
echo "  - Source image: ghcr.io/lpmi-13/k3s-remotelab-django"
echo "  - View workflow runs: https://localhost/gitea/remotelab/django-app/actions"
echo "  - Runner status: kubectl get pods -n applications -l app=act-runner"
echo ""
echo "Working with Git Repositories:"
echo "  The system uses HTTPS with self-signed certificates. You need to configure git:"
echo ""
echo "  Configure git to trust localhost (run this once):"
echo "    git config --global http.https://localhost/.sslVerify false"
echo ""
echo "Development Workflow - Clone, Edit, and Deploy:"
echo "  1. Configure git (one-time setup):"
echo "     git config --global http.https://localhost/.sslVerify false"
echo ""
echo "  2. Clone the Django app repository:"
echo "     git clone https://localhost/gitea/remotelab/django-app.git"
echo "     cd django-app"
echo ""
echo "  3. Make your code changes and commit:"
echo "     # Edit files as needed"
echo "     git add ."
echo "     git commit -m 'Description of your changes'"
echo ""
echo "  4. Push to trigger automatic deployment:"
echo "     git push origin main"
echo ""
echo "  5. Monitor the deployment pipeline:"
echo "     - Gitea Actions workflow: https://localhost/gitea/remotelab/django-app/actions"
echo "     - ArgoCD sync status: https://localhost/argocd"
echo "     - Pod status: kubectl get pods -n applications -l app=django -w"
echo "     - Application logs: kubectl logs -n applications -l app=django -f"
echo ""
echo "  What happens automatically:"
echo "     - Gitea Actions pulls latest image from ghcr.io/lpmi-13/k3s-remotelab-django"
echo "     - Image is pushed to local Gitea registry (gitea:3000/remotelab/django-app:1.0.1)"
echo "     - Security scanning runs via Trivy"
echo "     - ArgoCD detects changes and syncs deployment (if configured for auto-sync)"
echo ""
echo "Key Features:"
echo "  - mTLS encryption for all pod-to-pod communication via Linkerd service mesh"
echo "  - All services use path-based routing - no /etc/hosts configuration required"
echo "  - Fully automated CI/CD - no local Docker builds needed"
echo "  - Container images pulled from ghcr.io/lpmi-13/k3s-remotelab-django and cached in Gitea registry"
echo ""
echo "Verify mTLS Status:"
echo "  - Check Linkerd dashboard: export PATH=\$PATH:$(get_linkerd_path) && linkerd viz install | kubectl apply -f - && linkerd viz dashboard"
echo "  - View meshed pods: kubectl get pods -n applications -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.spec.containers[*].name}{\"\\n\"}{end}'"
echo ""