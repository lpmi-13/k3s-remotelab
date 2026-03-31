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

# Detect OS and handle context switching
OS=$(uname -s)

if [[ "$OS" == "Darwin" ]]; then
    echo "macOS detected - configuring Colima environment..."

    # Check if Colima is installed
    if ! command -v colima &>/dev/null; then
        echo "  ❌ ERROR: Colima is not installed"
        echo "  → Install with: brew install colima"
        exit 1
    fi

    # Ensure Colima is running with containerd runtime
    # Colima runtime can't be changed after VM creation, so we must
    # delete and recreate if it was created with docker runtime.
    COLIMA_RUNTIME=""
    if colima list --json 2>/dev/null | grep -q '"runtime":"docker"'; then
        COLIMA_RUNTIME="docker"
    elif colima list --json 2>/dev/null | grep -q '"runtime":"containerd"'; then
        COLIMA_RUNTIME="containerd"
    fi

    if [[ "$COLIMA_RUNTIME" == "docker" ]]; then
        echo "  ⚠ Colima is using Docker runtime — this stack requires containerd."
        echo "  → Deleting existing Colima instance and recreating with containerd..."
        colima delete --force --data
        COLIMA_RUNTIME=""
    fi

    if [[ -z "$COLIMA_RUNTIME" ]]; then
        echo "  → Cleaning up any leftover runtime data..."
        colima delete --force --data 2>/dev/null || true
        echo "  → Starting Colima with Kubernetes and containerd runtime..."
        colima start --kubernetes --runtime containerd --cpu 6 --memory 8 --disk 100
        echo "  → Waiting for Colima to initialize..."
        sleep 15
        echo "  ✓ Colima started with containerd runtime"
    elif ! colima status &>/dev/null; then
        echo "  → Colima VM exists but is not running. Starting..."
        colima start
        echo "  → Waiting for Colima to initialize..."
        sleep 15
        echo "  ✓ Colima started"
    else
        echo "  ✓ Colima is already running with containerd runtime"
    fi

    # Find any colima-related context
    echo "  → Detecting Colima Kubernetes context..."
    COLIMA_CONTEXT=$(kubectl config get-contexts -o name 2>/dev/null | grep -i "colima" | head -n 1)

    if [ -z "$COLIMA_CONTEXT" ]; then
        echo "  → Colima context not found, attempting to recover..."

        # Try restarting Kubernetes to trigger context re-registration
        echo "  → Restarting Colima Kubernetes to re-register context..."
        colima kubernetes reset --force 2>/dev/null || colima kubernetes start 2>/dev/null || true
        sleep 5

        # Retry finding context
        COLIMA_CONTEXT=$(kubectl config get-contexts -o name 2>/dev/null | grep -i "colima" | head -n 1)
    fi

    if [ -z "$COLIMA_CONTEXT" ]; then
        echo "  → Auto-registration failed, manually extracting kubeconfig..."

        # Extract kubeconfig from Colima VM and merge it
        KUBECONFIG_TEMP=$(mktemp)
        if colima ssh -- sudo cat /etc/rancher/k3s/k3s.yaml > "$KUBECONFIG_TEMP" 2>/dev/null; then
            # Get the server port from the extracted config
            SERVER_PORT=$(grep -o 'server: https://127.0.0.1:[0-9]*' "$KUBECONFIG_TEMP" | grep -o '[0-9]*$')

            if [ -n "$SERVER_PORT" ]; then
                # Extract base64-encoded certificates
                CERT_DATA_B64=$(grep 'certificate-authority-data:' "$KUBECONFIG_TEMP" | awk '{print $2}')
                CLIENT_CERT_B64=$(grep 'client-certificate-data:' "$KUBECONFIG_TEMP" | awk '{print $2}')
                CLIENT_KEY_B64=$(grep 'client-key-data:' "$KUBECONFIG_TEMP" | awk '{print $2}')

                # Decode certificates to temp files (kubectl needs file paths, not raw data)
                CA_FILE=$(mktemp)
                CERT_FILE=$(mktemp)
                KEY_FILE=$(mktemp)
                echo "$CERT_DATA_B64" | base64 -d > "$CA_FILE"
                echo "$CLIENT_CERT_B64" | base64 -d > "$CERT_FILE"
                echo "$CLIENT_KEY_B64" | base64 -d > "$KEY_FILE"

                # Create the colima cluster, credentials, and context
                kubectl config set-cluster colima \
                    --server="https://127.0.0.1:${SERVER_PORT}" \
                    --certificate-authority="$CA_FILE" \
                    --embed-certs=true 2>/dev/null

                kubectl config set-credentials colima \
                    --client-certificate="$CERT_FILE" \
                    --client-key="$KEY_FILE" \
                    --embed-certs=true 2>/dev/null

                kubectl config set-context colima \
                    --cluster=colima \
                    --user=colima 2>/dev/null

                # Clean up temp cert files
                rm -f "$CA_FILE" "$CERT_FILE" "$KEY_FILE"

                COLIMA_CONTEXT="colima"
                echo "  ✓ Manually created colima context"
            fi
        fi
        rm -f "$KUBECONFIG_TEMP"
    fi

    if [ -z "$COLIMA_CONTEXT" ]; then
        echo "  ❌ ERROR: Could not create or find Colima kubectl context"
        echo ""
        echo "Available contexts:"
        kubectl config get-contexts -o name | sed 's/^/    - /'
        echo ""
        echo "Try manually resetting Colima:"
        echo "  colima delete --data && colima start --kubernetes --runtime containerd --cpu 6 --memory 8 --disk 100"
        exit 1
    fi

    echo "  ✓ Found Colima context: ${COLIMA_CONTEXT}"

    # Automatically switch to colima context
    echo "  → Switching to ${COLIMA_CONTEXT} context..."
    kubectl config use-context "${COLIMA_CONTEXT}" > /dev/null

    # Verify we're on the correct colima context
    CURRENT_CONTEXT=$(kubectl config current-context)
    if [[ "$CURRENT_CONTEXT" != "$COLIMA_CONTEXT" ]]; then
        echo "  ❌ ERROR: Failed to switch to colima context"
        echo "  Expected: ${COLIMA_CONTEXT}"
        echo "  Current: ${CURRENT_CONTEXT}"
        exit 1
    fi

    echo "  ✓ Successfully switched to ${COLIMA_CONTEXT} context"

    # Verify kubectl can actually connect to the cluster
    echo "  → Verifying cluster connectivity..."
    if ! kubectl cluster-info &>/dev/null; then
        echo "  ❌ ERROR: Cannot connect to Colima Kubernetes cluster"
        echo "  → The context exists but the cluster is not responding"
        echo "  → Try: colima kubernetes reset"
        exit 1
    fi
    echo "  ✓ Cluster is responding"
else
    echo "Linux detected - verifying kubectl configuration..."
    # On Linux, just verify kubectl is working
    if ! kubectl cluster-info &>/dev/null; then
        echo "  ❌ ERROR: Cannot connect to Kubernetes cluster"
        echo "  → Ensure k3s is installed and running"
        exit 1
    fi
    echo "  ✓ kubectl is configured and working"
fi

# Verify nodes are using containerd, not Docker.
# The k3s container registry setup requires containerd.
echo "  → Verifying container runtime on cluster nodes..."
NODE_RUNTIMES=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.containerRuntimeVersion}{"\n"}{end}' 2>/dev/null)
if echo "$NODE_RUNTIMES" | grep -qi docker; then
    echo "  ⚠ Docker container runtime detected on node(s):"
    echo "$NODE_RUNTIMES" | sed 's/^/       /'
    if [[ "$OS" == "Darwin" ]]; then
        echo "  → Deleting Colima VM and recreating with containerd..."
        colima delete --force --data
        colima start --kubernetes --runtime containerd --cpu 6 --memory 8 --disk 100
        echo "  → Waiting for Colima to initialize..."
        sleep 15
        echo "  ✓ Colima recreated with containerd runtime"

        # Re-verify the runtime after recreation
        NODE_RUNTIMES=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.containerRuntimeVersion}{"\n"}{end}' 2>/dev/null)
        if echo "$NODE_RUNTIMES" | grep -qi docker; then
            echo "  ❌ ERROR: Nodes are still reporting Docker runtime after Colima recreation."
            echo "$NODE_RUNTIMES" | sed 's/^/       /'
            exit 1
        fi
    else
        echo "  ❌ ERROR: This stack requires containerd."
        echo "  → Ensure k3s is configured with containerd (the default) and not Docker."
        exit 1
    fi
fi
echo "  ✓ All nodes using containerd"
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

# Check disk space early to warn about potential issues
echo "Step 0: Pre-flight checks..."
echo "  → Checking disk space..."
if command -v colima &>/dev/null && colima status &>/dev/null; then
    # Colima on macOS
    DISK_USAGE=$(colima ssh -- df -h / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%' || echo "0")
    DISK_AVAIL=$(colima ssh -- df -h / 2>/dev/null | tail -1 | awk '{print $4}' || echo "unknown")
else
    # Native k3s on Linux
    DISK_USAGE=$(df -h / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%' || echo "0")
    DISK_AVAIL=$(df -h / 2>/dev/null | tail -1 | awk '{print $4}' || echo "unknown")
fi

if [ "$DISK_USAGE" -gt 85 ] 2>/dev/null; then
    echo "  ⚠ WARNING: Disk usage is ${DISK_USAGE}% (${DISK_AVAIL} available)"
    echo "  ⚠ Deployment may fail due to disk pressure. Cleanup will be attempted."
else
    echo "  ✓ Disk space OK (${DISK_USAGE}% used, ${DISK_AVAIL} available)"
fi

# Configure k3s registries for Gitea container registry
echo ""
echo "  → Configuring k3s registry mirrors..."
if command -v colima &>/dev/null && colima status &>/dev/null; then
    # Colima on macOS - configure registries.yaml
    cat > /tmp/registries.yaml <<'EOF'
mirrors:
  "localhost:30300":
    endpoint:
      - "http://localhost:30300"
  docker.io:
    endpoint:
      - "https://registry-1.docker.io"
EOF
    colima ssh -- sudo mkdir -p /etc/rancher/k3s
    colima ssh -- sudo tee /etc/rancher/k3s/registries.yaml < /tmp/registries.yaml > /dev/null
    rm /tmp/registries.yaml

    # Restart k3s to apply registry configuration
    colima ssh -- sh -c 'sudo systemctl restart k3s' 2>/dev/null || true
    echo "  ✓ k3s registry configuration applied"
    echo "  → Waiting for k3s to restart..."
    sleep 15
elif [ -d "/etc/rancher/k3s" ]; then
    # Native k3s on Linux
    sudo tee /etc/rancher/k3s/registries.yaml > /dev/null <<'EOF'
mirrors:
  "localhost:30300":
    endpoint:
      - "http://localhost:30300"
  docker.io:
    endpoint:
      - "https://registry-1.docker.io"
EOF
    sudo systemctl restart k3s 2>/dev/null || true
    echo "  ✓ k3s registry configuration applied"
    sleep 10
else
    echo "  ⚠ Warning: Could not configure k3s registries (not Colima or native k3s)"
fi

# Check if any resources exist and clean up for idempotent deployment
if [ "$SKIP_CLEANUP" = false ]; then
    echo ""
    echo "  → Checking for existing resources..."
    RESOURCES_EXIST=false

    # Check for existing namespaces
    if kubectl get namespace argocd &>/dev/null || \
       kubectl get namespace applications &>/dev/null || \
       kubectl get namespace monitoring &>/dev/null; then
        RESOURCES_EXIST=true
    fi

    if [ "$RESOURCES_EXIST" = true ]; then
        echo "  ⚠ Existing resources detected. Cleaning up for fresh deployment..."

        # Clean up failed/evicted pods to free disk space (prevents disk pressure)
        echo "  → Cleaning up failed and evicted pods..."
        kubectl delete pods --all-namespaces --field-selector=status.phase=Failed --ignore-not-found=true 2>/dev/null || true
        kubectl delete pods --all-namespaces --field-selector=status.phase=Succeeded --ignore-not-found=true 2>/dev/null || true
        # Force delete pods stuck in bad states
        for ns in applications argocd monitoring; do
            kubectl get pods -n "$ns" 2>/dev/null | grep -E 'Evicted|Error|ContainerStatusUnknown' | awk '{print $1}' | \
                xargs -r kubectl delete pod -n "$ns" --force --grace-period=0 2>/dev/null || true
        done
        echo "  ✓ Failed pods cleaned up"

        # Prune unused container images to free disk space
        echo "  → Pruning unused container images..."
        if command -v colima &>/dev/null && colima status &>/dev/null; then
            # Colima on macOS
            colima ssh -- sudo k3s crictl rmi --prune 2>/dev/null || true
        elif command -v crictl &>/dev/null; then
            # Native k3s on Linux
            sudo crictl rmi --prune 2>/dev/null || true
        fi
        echo "  ✓ Container images pruned"

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

        # Delete ArgoCD applications BEFORE deleting Gitea repos
        # This prevents stale commit SHA references when repos are recreated
        echo "  → Deleting ArgoCD applications (prevents stale revision cache)..."
        if kubectl get namespace argocd &>/dev/null; then
            # Remove finalizers first, then delete
            kubectl get applications.argoproj.io -n argocd -o name 2>/dev/null | \
                xargs -I {} kubectl patch {} -n argocd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            kubectl delete applications.argoproj.io --all -n argocd --ignore-not-found=true --wait=false 2>/dev/null || true
            echo "  ✓ ArgoCD applications deleted"
        fi

        # Delete Gitea repositories via API to ensure fresh state
        echo "  → Deleting Gitea repositories..."
        if curl -sf -o /dev/null http://localhost:30300/api/v1/version 2>/dev/null; then
            curl -X DELETE "http://localhost:30300/api/v1/repos/remotelab/manifests" \
                -u "remotelab:remotelab" --connect-timeout 5 2>/dev/null || true
            curl -X DELETE "http://localhost:30300/api/v1/repos/remotelab/django-app" \
                -u "remotelab:remotelab" --connect-timeout 5 2>/dev/null || true
            echo "  ✓ Gitea repositories deleted"
        else
            echo "  ✓ Gitea not running, skipping repo deletion"
        fi

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
echo "Step 1: Deploying Kubernetes resources..."

# Deploy namespaces first
echo "  → Creating namespaces..."
kubectl apply -f manifests/monitoring/namespace.yaml
kubectl apply -f manifests/applications/namespace.yaml
kubectl apply -f manifests/gitops/argocd-namespace.yaml
echo "  ✓ Namespaces created"

echo ""
echo "Step 2: Installing ArgoCD..."
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "  → Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
echo "  ✓ ArgoCD ready"

echo "  → Applying ArgoCD customizations..."
kubectl apply -f manifests/gitops/argocd-cmd-params-cm.yaml
kubectl apply -f manifests/gitops/argocd-ingress.yaml
kubectl apply -f manifests/gitops/argocd-oci-secret.yaml

# Create ArgoCD repository secret for Gitea Helm package registry (with insecure TLS)
# This is needed because Gitea returns HTTPS download URLs using ROOT_URL
echo "  → Creating ArgoCD repository secret for Gitea Helm registry..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: gitea-helm-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  name: gitea-helm
  url: http://gitea.applications.svc.cluster.local:3000/api/packages/remotelab/helm
  insecure: "true"
  insecureIgnoreHostKey: "true"
  enableLfs: "false"
EOF

echo "  → Patching ArgoCD server for subpath support..."
kubectl patch deployment argocd-server -n argocd --type='strategic' --patch-file manifests/gitops/argocd-server-patch.yaml
kubectl wait --for=condition=available --timeout=120s deployment/argocd-server -n argocd
echo "  ✓ ArgoCD configured"

echo ""
echo "Step 3: Deploying monitoring stack..."
kubectl apply -f manifests/monitoring/
echo "  → Waiting for Prometheus..."
kubectl wait --for=condition=available --timeout=300s deployment/prometheus -n monitoring
echo "  ✓ Monitoring stack ready"

echo ""
echo "Step 4: Deploying infrastructure applications..."
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
echo "Step 5: Ensuring Traefik ingress controller is installed..."
# Check if Traefik CRDs exist (indicates Traefik is installed)
if ! kubectl get crd middlewares.traefik.io &>/dev/null; then
    echo "  → Traefik not found, installing via Helm..."

    # Add Traefik Helm repo if not present
    if ! helm repo list 2>/dev/null | grep -q "^traefik"; then
        helm repo add traefik https://traefik.github.io/charts
    fi
    helm repo update traefik

    # Install Traefik
    helm install traefik traefik/traefik \
        --namespace kube-system \
        --set service.type=LoadBalancer \
        --set ingressClass.enabled=true \
        --set ingressClass.isDefaultClass=true

    echo "  → Waiting for Traefik to be ready..."
    kubectl wait --for=condition=available --timeout=120s deployment/traefik -n kube-system
    echo "  ✓ Traefik installed"
else
    echo "  ✓ Traefik already installed"
fi

echo ""
echo "  → Patching ArgoCD repo-server for localhost resolution..."
# Get the Traefik ClusterIP for hostAliases
TRAEFIK_IP=$(kubectl get svc traefik -n kube-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [ -n "$TRAEFIK_IP" ]; then
    # Patch ArgoCD repo-server with hostAliases to resolve localhost to Traefik
    # This is needed because Gitea's Helm Package API returns download URLs using ROOT_URL
    # (https://localhost/gitea/...) which doesn't work from inside pods.
    kubectl patch deployment argocd-repo-server -n argocd --type='strategic' -p "{
      \"spec\": {
        \"template\": {
          \"spec\": {
            \"hostAliases\": [{
              \"ip\": \"$TRAEFIK_IP\",
              \"hostnames\": [\"localhost\"]
            }]
          }
        }
      }
    }"
    echo "  ✓ ArgoCD repo-server patched (localhost → $TRAEFIK_IP)"
    # Wait for the patched repo-server to restart
    kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=120s
else
    echo "  ⚠ Warning: Could not get Traefik ClusterIP, skipping hostAliases patch"
fi

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
echo "Step 11: Verifying Helm chart in Gitea package registry..."
# The gitea-init-repo job packages and pushes the initial Helm chart.
# Verify it's available before proceeding to ArgoCD deployment.
MAX_CHART_WAIT=60
CHART_WAIT=0
while [ $CHART_WAIT -lt $MAX_CHART_WAIT ]; do
    if kubectl exec -n applications deployment/gitea -c gitea -- \
        curl -sf "http://localhost:3000/api/packages/remotelab/helm/api/charts" 2>/dev/null | grep -q "django-app"; then
        echo "  ✓ Helm chart found in Gitea package registry"
        break
    fi
    sleep 5
    CHART_WAIT=$((CHART_WAIT + 5))
    if [ $CHART_WAIT -lt $MAX_CHART_WAIT ]; then
        echo "  → Waiting for Helm chart to appear... (${CHART_WAIT}s)"
    fi
done

if [ $CHART_WAIT -ge $MAX_CHART_WAIT ]; then
    echo "  ⚠ Warning: Helm chart not found after ${MAX_CHART_WAIT}s"
    echo "  → The init-repo job may not have pushed it yet. Continuing anyway..."
fi

echo ""
echo "Step 12: Deploying ArgoCD Applications..."
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
echo "Step 13: Waiting for Django to be deployed via ArgoCD..."
echo "  → Waiting for ArgoCD to sync django-api application..."
sleep 30  # Give ArgoCD time to detect and sync the Helm chart

# Wait for Django deployment to be ready
echo "  → Waiting for Django deployment to be ready..."
MAX_WAIT=120
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if kubectl get deployment django -n applications &>/dev/null; then
        READY=$(kubectl get deployment django -n applications -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [ "${READY:-0}" -ge 1 ]; then
            echo "  ✓ Django deployment ready"
            break
        fi
    fi
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    echo "  → Still waiting for Django... (${WAIT_COUNT}s)"
done

if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    echo "  ⚠ Warning: Django deployment not ready after ${MAX_WAIT}s"
    echo "  → Check ArgoCD status: kubectl get applications -n argocd django-api"
    echo "  → Check pod status: kubectl get pods -n applications -l app.kubernetes.io/name=django-app"
fi

# Verify Django health endpoint
echo "  → Testing Django health endpoint..."
sleep 5
if curl -sk https://localhost/django/api/health/ | grep -q "healthy"; then
    echo "  ✓ Django is healthy and responding"
else
    echo "  ⚠ Warning: Django health check failed (may still be starting)"
fi

echo ""
echo "========================================"
echo "  Deployment Complete!"
echo "========================================"
echo ""
echo "Services Available (HTTPS with self-signed certificates):"
echo "  - ArgoCD:     https://localhost/argocd"
echo "  - Gitea:      https://localhost/gitea (username: remotelab, password: remotelab)"
echo "  - Django API: https://localhost/django"
echo "  - Prometheus: https://localhost/prometheus"
echo "  - Grafana:    https://localhost/grafana (admin/admin)"
echo ""
echo "  Note: Accept the self-signed certificate warning in your browser"
echo ""
echo "ArgoCD Credentials:"
echo "  Username: admin"
echo "  Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "Check ArgoCD logs if password retrieval fails")"
echo ""
echo "Gitea Credentials:"
echo "  Username: remotelab"
echo "  Password: remotelab"
echo ""
echo "Development Workflow:"
echo "  1. Configure git (one-time setup):"
echo "     git config --global http.https://localhost/.sslVerify false"
echo ""
echo "  2. Clone the Django app repository:"
echo "     git clone https://localhost/gitea/remotelab/django-app.git"
echo "     cd django-app"
echo ""
echo "  3. Make changes, commit, and push:"
echo "     git add . && git commit -m 'My change' && git push origin main"
echo ""
echo "  4. Monitor the pipeline:"
echo "     - Gitea Actions: https://localhost/gitea/remotelab/django-app/actions"
echo "     - ArgoCD:        https://localhost/argocd"
echo "     - Pod status:    kubectl get pods -n applications -l app.kubernetes.io/name=django-app -w"
echo ""