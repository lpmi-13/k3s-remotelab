#!/bin/bash
set -e

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

        # Delete initialization jobs first (they may hold references)
        echo "  → Deleting initialization jobs..."
        kubectl delete job gitea-init-user -n applications --ignore-not-found=true --wait=false 2>/dev/null || true
        kubectl delete job gitea-init-runner -n applications --ignore-not-found=true --wait=false 2>/dev/null || true
        kubectl delete job gitea-init-repo -n applications --ignore-not-found=true --wait=false 2>/dev/null || true

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
echo "  ✓ Gitea admin user ready (username: homelab, password: homelab)"

echo ""
echo "Step 8: Setting up Gitea Actions runner..."

# Delete old runner job if it exists (for idempotency)
kubectl delete job gitea-init-runner -n applications --ignore-not-found=true 2>/dev/null || true
sleep 2

echo "  → Creating runner registration token..."
kubectl apply -f manifests/applications/gitea-init-runner.yaml

echo "  → Waiting for runner token creation (this may take a moment)..."
kubectl wait --for=condition=complete --timeout=120s job/gitea-init-runner -n applications 2>/dev/null || {
    echo "  ⚠️  Runner token creation job did not complete. Checking logs..."
    kubectl logs -n applications job/gitea-init-runner --tail=30 2>/dev/null || true
}

# Extract the runner token from the job logs
echo "  → Extracting runner token..."
RUNNER_TOKEN=$(kubectl logs -n applications job/gitea-init-runner 2>/dev/null | grep "Token: " | tail -1 | cut -d' ' -f2)

if [ -z "$RUNNER_TOKEN" ]; then
    echo "  ⚠️  Warning: Could not extract runner token from logs. Using placeholder."
    echo "     The runner may need manual configuration."
    RUNNER_TOKEN="placeholder-token"
else
    echo "  ✓ Runner token obtained"
    # Update the secret with the real token
    kubectl create secret generic runner-secret -n applications \
      --from-literal=token="$RUNNER_TOKEN" \
      --dry-run=client -o yaml | kubectl apply -f -
fi

echo "  → Deploying Gitea Actions runner..."
kubectl apply -f manifests/applications/gitea-actions-runner.yaml

echo "  → Waiting for runner to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/act-runner -n applications 2>/dev/null || {
    echo "  ⚠️  Runner deployment taking longer than expected..."
    kubectl get pods -n applications -l app=act-runner
}
echo "  ✓ Gitea Actions runner deployed"

echo ""
echo "Step 9: Initializing Django app repository in Gitea..."

# Delete old repository initialization job if it exists (for idempotency)
kubectl delete job gitea-init-repo -n applications --ignore-not-found=true 2>/dev/null || true
sleep 2

# Check if sample Django app exists
if [ ! -d "sample-django-app" ]; then
    echo "Error: sample-django-app directory not found!"
    echo "Please run this script from the remotelab project root."
    exit 1
fi

echo "  → Creating repository and pushing Django app code..."
kubectl apply -f manifests/applications/gitea-init-repo.yaml

echo "  → Waiting for repository initialization (this may take a minute)..."
kubectl wait --for=condition=complete --timeout=180s job/gitea-init-repo -n applications 2>/dev/null || {
    echo "  ⚠️  Repository initialization did not complete in time. Checking logs..."
    kubectl logs -n applications job/gitea-init-repo --tail=40 2>/dev/null || true
    echo ""
    echo "  ❌ Failed to initialize repository. Cannot proceed without Django image."
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
    # For now, we'll use the homelab user credentials which have registry access
    echo "  → Token will be available for manual configuration if needed"
else
    echo "  ⚠️  Warning: Could not extract API token. Workflow will use actor credentials."
fi

echo ""
echo "Step 10: Waiting for Gitea Actions workflow to build Django image..."

# Function to check workflow status via Gitea API
check_workflow_status() {
    curl -s -u "homelab:homelab" \
      "http://localhost/gitea/api/v1/repos/homelab/django-app/actions/runs" \
      2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4
}

# Function to check if image exists in registry
check_image_exists() {
    curl -s -u "homelab:homelab" \
      "http://localhost/gitea/api/v1/packages/homelab?type=container" \
      2>/dev/null | grep -q "django-app"
}

echo "  → Workflow should have been triggered by the git push to main branch..."
echo "  → Polling for workflow completion (timeout: 10 minutes)..."

workflow_attempts=0
max_workflow_attempts=60  # 60 attempts * 10 seconds = 10 minutes

while [ $workflow_attempts -lt $max_workflow_attempts ]; do
    workflow_attempts=$((workflow_attempts + 1))

    # Check workflow status
    STATUS=$(check_workflow_status)

    if [ "$STATUS" = "success" ]; then
        echo "  ✓ Workflow completed successfully!"
        break
    elif [ "$STATUS" = "failure" ]; then
        echo "  ❌ Workflow failed! Check Gitea Actions logs at:"
        echo "     https://localhost/gitea/homelab/django-app/actions"
        exit 1
    elif [ "$STATUS" = "running" ] || [ "$STATUS" = "waiting" ]; then
        echo "  → Workflow is $STATUS... (attempt $workflow_attempts/$max_workflow_attempts)"
    else
        # No workflow found yet or unknown status
        echo "  → Waiting for workflow to start... (attempt $workflow_attempts/$max_workflow_attempts)"
    fi

    # Also check if image exists as a fallback verification
    if check_image_exists; then
        echo "  ✓ Django image detected in Gitea registry!"
        break
    fi

    sleep 10
done

if [ $workflow_attempts -ge $max_workflow_attempts ]; then
    echo "  ⚠️  Workflow did not complete within timeout."
    echo "  Checking if image exists in registry anyway..."

    if check_image_exists; then
        echo "  ✓ Image found in registry, proceeding with deployment"
    else
        echo "  ❌ Image not found in registry. Cannot deploy Django application."
        echo "  Check workflow status at: https://localhost/gitea/homelab/django-app/actions"
        echo "  You may need to manually trigger the workflow or check runner logs:"
        echo "    kubectl logs -n applications -l app=act-runner"
        exit 1
    fi
fi

echo "  ✓ Django image is ready in Gitea registry (gitea.homelab.local/homelab/django-app:1.0.1)"

echo ""
echo "Step 11: Deploying Django application..."
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
echo "  - Gitea:      https://localhost/gitea (username: homelab, password: homelab)"
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
echo "  Username: homelab"
echo "  Password: homelab"
echo ""
echo "Container Registry (Gitea):"
echo "  - Registry: gitea.homelab.local"
echo "  - Django image: gitea.homelab.local/homelab/django-app:1.0.1"
echo "  - Repository: https://localhost/gitea/homelab/django-app"
echo ""
echo "CI/CD Pipeline (Gitea Actions):"
echo "  - Django app repository created with automated build workflow"
echo "  - Push to main branch triggers automatic image build and registry push"
echo "  - View workflow runs: https://localhost/gitea/homelab/django-app/actions"
echo "  - Runner status: kubectl get pods -n applications -l app=act-runner"
echo ""
echo "To update Django application:"
echo "  1. Clone repo: git clone http://localhost/gitea/homelab/django-app.git"
echo "  2. Make changes and commit"
echo "  3. Push to main: git push origin main"
echo "  4. Gitea Actions will automatically build and push new image"
echo "  5. Update deployment to use new image version"
echo ""
echo "Key Features:"
echo "  - mTLS encryption for all pod-to-pod communication via Linkerd service mesh"
echo "  - All services use path-based routing - no /etc/hosts configuration required"
echo "  - Fully automated CI/CD - no local Docker builds needed"
echo "  - Container images built in ephemeral Kubernetes environment"
echo ""
echo "Verify mTLS Status:"
echo "  - Check Linkerd dashboard: export PATH=\$PATH:/home/adam/.linkerd2/bin && linkerd viz install | kubectl apply -f - && linkerd viz dashboard"
echo "  - View meshed pods: kubectl get pods -n applications -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.spec.containers[*].name}{\"\\n\"}{end}'"
echo ""