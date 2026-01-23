#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/platform.sh"

# Show help message
show_help() {
    echo "Usage: ./cleanup-all.sh [OPTIONS]"
    echo ""
    echo "Clean up all resources created by deploy-all.sh from the K3s cluster."
    echo ""
    echo "Options:"
    echo "  --yes, -y         Skip confirmation prompt and proceed with cleanup"
    echo "  --help, -h        Show this help message"
    echo ""
    echo "This script will remove:"
    echo "  - Failed and evicted pods from all namespaces"
    echo "  - Unused container images (frees disk space)"
    echo "  - Initialization jobs (gitea-init-user, gitea-init-repo, gitea-init-manifests)"
    echo "  - Persistent volume claims (gitea-pvc, postgres-pvc, redis-data)"
    echo "  - ArgoCD applications (with finalizer removal)"
    echo "  - Gitea repositories via API (manifests and django-app)"
    echo "  - Namespaces: applications, monitoring, argocd (with finalizer removal)"
    echo "  - Linkerd service mesh (namespaces and CRDs)"
    echo "  - Traefik ingress controller (Helm release and CRDs)"
    echo "  - Gateway API CRDs"
    echo "  - Orphaned persistent volumes"
    echo ""
    echo "Examples:"
    echo "  ./cleanup-all.sh        # Clean up with confirmation prompt"
    echo "  ./cleanup-all.sh --yes  # Clean up without confirmation"
    echo ""
    exit 0
}

# Parse command line arguments
SKIP_CONFIRMATION=false
if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    show_help
elif [[ "$1" == "--yes" ]] || [[ "$1" == "-y" ]]; then
    SKIP_CONFIRMATION=true
elif [[ -n "$1" ]]; then
    echo "Error: Unknown option '$1'"
    echo ""
    show_help
fi

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

# Confirmation prompt
if [ "$SKIP_CONFIRMATION" = false ]; then
    echo "=== Remotelab K3s Stack Cleanup ==="
    echo ""
    echo "WARNING: This will permanently delete all resources created by deploy-all.sh:"
    echo "  - All namespaces: applications, monitoring, argocd"
    echo "  - All persistent data (Gitea repositories, PostgreSQL databases, etc.)"
    echo "  - All ArgoCD applications and configurations"
    echo "  - Container images and persistent volumes"
    echo ""
    read -p "Are you sure you want to proceed? (yes/no): " -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Cleanup cancelled."
        exit 0
    fi
fi

echo "=== Starting Cleanup Process ==="
echo ""

# Switch to local cluster context
echo "Step 1: Ensuring kubectl is configured for local cluster..."
switch_to_local_context || {
    echo "Warning: Could not switch to local cluster context. Continuing with current context."
    echo "Current context: $(kubectl config current-context 2>/dev/null || echo 'none')"
}
echo ""

# Clean up failed/evicted pods to free disk space
echo "Step 2: Cleaning up failed and evicted pods..."
kubectl delete pods --all-namespaces --field-selector=status.phase=Failed --ignore-not-found=true 2>/dev/null || {
    echo "  ⚠ Warning: Failed to delete some Failed pods (continuing anyway)"
}
kubectl delete pods --all-namespaces --field-selector=status.phase=Succeeded --ignore-not-found=true 2>/dev/null || {
    echo "  ⚠ Warning: Failed to delete some Succeeded pods (continuing anyway)"
}

# Force delete pods stuck in bad states
echo "  → Force deleting pods in bad states..."
for ns in applications argocd monitoring; do
    if kubectl get namespace "$ns" &>/dev/null; then
        kubectl get pods -n "$ns" 2>/dev/null | grep -E 'Evicted|Error|ContainerStatusUnknown' | awk '{print $1}' | \
            xargs -r kubectl delete pod -n "$ns" --force --grace-period=0 2>/dev/null || true
    fi
done
echo "  ✓ Failed pods cleaned up"
echo ""

# Prune unused container images to free disk space
echo "Step 3: Pruning unused container images..."
if command -v colima &>/dev/null && colima status &>/dev/null; then
    # Colima on macOS
    echo "  → Pruning images in Colima VM..."
    colima ssh -- sudo k3s crictl rmi --prune 2>/dev/null || {
        echo "  ⚠ Warning: Failed to prune images (continuing anyway)"
    }
elif command -v crictl &>/dev/null; then
    # Native k3s on Linux
    echo "  → Pruning images on native k3s..."
    sudo crictl rmi --prune 2>/dev/null || {
        echo "  ⚠ Warning: Failed to prune images (continuing anyway)"
    }
else
    echo "  ⚠ Warning: crictl not found, skipping image pruning"
fi
echo "  ✓ Container images pruned"
echo ""

# Delete initialization jobs first (they may hold references)
echo "Step 4: Deleting initialization jobs..."
kubectl delete job gitea-init-user -n applications --ignore-not-found=true --wait=false 2>/dev/null || {
    echo "  ⚠ Warning: Failed to delete gitea-init-user job (continuing anyway)"
}
kubectl delete job gitea-init-repo -n applications --ignore-not-found=true --wait=false 2>/dev/null || {
    echo "  ⚠ Warning: Failed to delete gitea-init-repo job (continuing anyway)"
}
kubectl delete job gitea-init-manifests -n applications --ignore-not-found=true --wait=false 2>/dev/null || {
    echo "  ⚠ Warning: Failed to delete gitea-init-manifests job (continuing anyway)"
}
echo "  ✓ Initialization jobs deleted"
echo ""

# Explicitly delete PVCs to trigger storage cleanup
echo "Step 5: Deleting PVCs to cleanup persistent storage..."
kubectl delete pvc gitea-pvc -n applications --ignore-not-found=true --wait=true --timeout=30s 2>/dev/null || {
    echo "  ⚠ Warning: Failed to delete gitea-pvc (continuing anyway)"
}
kubectl delete pvc postgres-pvc -n applications --ignore-not-found=true --wait=true --timeout=30s 2>/dev/null || {
    echo "  ⚠ Warning: Failed to delete postgres-pvc (continuing anyway)"
}
kubectl delete pvc redis-data -n applications --ignore-not-found=true --wait=true --timeout=30s 2>/dev/null || {
    echo "  ⚠ Warning: Failed to delete redis-data (continuing anyway)"
}
echo "  → Waiting for storage cleanup..."
sleep 3  # Give local-path-provisioner time to cleanup storage directories
echo "  ✓ PVCs deleted"
echo ""

# Delete ArgoCD applications BEFORE deleting Gitea repos
echo "Step 6: Deleting ArgoCD applications..."
if kubectl get namespace argocd &>/dev/null; then
    # Remove finalizers first, then delete
    echo "  → Removing finalizers from ArgoCD applications..."
    kubectl get applications.argoproj.io -n argocd -o name 2>/dev/null | \
        xargs -I {} kubectl patch {} -n argocd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || {
        echo "  ⚠ Warning: Failed to remove some finalizers (continuing anyway)"
    }

    echo "  → Deleting all ArgoCD applications..."
    kubectl delete applications.argoproj.io --all -n argocd --ignore-not-found=true --wait=false 2>/dev/null || {
        echo "  ⚠ Warning: Failed to delete some applications (continuing anyway)"
    }
    echo "  ✓ ArgoCD applications deleted"
else
    echo "  ✓ ArgoCD namespace not found, skipping application deletion"
fi
echo ""

# Delete Gitea repositories via API to ensure fresh state
echo "Step 7: Deleting Gitea repositories..."
if curl -sf -o /dev/null http://localhost:30300/api/v1/version 2>/dev/null; then
    echo "  → Deleting manifests repository..."
    curl -X DELETE "http://localhost:30300/api/v1/repos/remotelab/manifests" \
        -u "remotelab:remotelab" --connect-timeout 5 2>/dev/null || {
        echo "  ⚠ Warning: Failed to delete manifests repository (may not exist)"
    }

    echo "  → Deleting django-app repository..."
    curl -X DELETE "http://localhost:30300/api/v1/repos/remotelab/django-app" \
        -u "remotelab:remotelab" --connect-timeout 5 2>/dev/null || {
        echo "  ⚠ Warning: Failed to delete django-app repository (may not exist)"
    }
    echo "  ✓ Gitea repositories deleted"
else
    echo "  ✓ Gitea not running, skipping repository deletion"
fi
echo ""

# Force delete namespaces with finalizer removal
echo "Step 8: Force deleting namespaces..."
echo ""

# Delete in reverse order of dependencies
echo "  → Deleting applications namespace..."
force_delete_namespace "applications" || {
    echo "  ⚠ Warning: Failed to fully delete applications namespace (continuing anyway)"
}
echo ""

echo "  → Deleting monitoring namespace..."
force_delete_namespace "monitoring" || {
    echo "  ⚠ Warning: Failed to fully delete monitoring namespace (continuing anyway)"
}
echo ""

echo "  → Deleting argocd namespace..."
force_delete_namespace "argocd" || {
    echo "  ⚠ Warning: Failed to fully delete argocd namespace (continuing anyway)"
}
echo ""

# Remove Linkerd service mesh
echo "Step 9: Removing Linkerd service mesh..."
echo ""

echo "  → Deleting linkerd-viz namespace..."
force_delete_namespace "linkerd-viz" || {
    echo "  ⚠ Warning: Failed to fully delete linkerd-viz namespace (continuing anyway)"
}
echo ""

echo "  → Deleting linkerd namespace..."
force_delete_namespace "linkerd" || {
    echo "  ⚠ Warning: Failed to fully delete linkerd namespace (continuing anyway)"
}
echo ""

echo "  → Deleting Linkerd CRDs..."
LINKERD_CRDS=$(kubectl get crd -o name 2>/dev/null | grep "linkerd.io" || true)
if [ -n "$LINKERD_CRDS" ]; then
    echo "$LINKERD_CRDS" | xargs kubectl delete --ignore-not-found=true 2>/dev/null || {
        echo "  ⚠ Warning: Failed to delete some Linkerd CRDs (continuing anyway)"
    }
    echo "  ✓ Linkerd CRDs deleted"
else
    echo "  ✓ No Linkerd CRDs found"
fi
echo ""

# Remove Traefik ingress controller
echo "Step 10: Removing Traefik ingress controller..."
echo ""

echo "  → Uninstalling Traefik Helm release..."
if helm list -n kube-system 2>/dev/null | grep -q "^traefik"; then
    helm uninstall traefik -n kube-system 2>/dev/null || {
        echo "  ⚠ Warning: Failed to uninstall Traefik Helm release (continuing anyway)"
    }
    echo "  ✓ Traefik Helm release uninstalled"
else
    echo "  ✓ Traefik Helm release not found"
fi
echo ""

echo "  → Deleting Traefik CRDs..."
TRAEFIK_CRDS=$(kubectl get crd -o name 2>/dev/null | grep "traefik.io" || true)
if [ -n "$TRAEFIK_CRDS" ]; then
    echo "$TRAEFIK_CRDS" | xargs kubectl delete --ignore-not-found=true 2>/dev/null || {
        echo "  ⚠ Warning: Failed to delete some Traefik CRDs (continuing anyway)"
    }
    echo "  ✓ Traefik CRDs deleted"
else
    echo "  ✓ No Traefik CRDs found"
fi
echo ""

# Remove Gateway API CRDs
echo "Step 11: Removing Gateway API CRDs..."
echo ""

echo "  → Deleting Gateway API CRDs..."
GATEWAY_CRDS=$(kubectl get crd -o name 2>/dev/null | grep "gateway.networking.k8s.io" || true)
if [ -n "$GATEWAY_CRDS" ]; then
    echo "$GATEWAY_CRDS" | xargs kubectl delete --ignore-not-found=true 2>/dev/null || {
        echo "  ⚠ Warning: Failed to delete some Gateway API CRDs (continuing anyway)"
    }
    echo "  ✓ Gateway API CRDs deleted"
else
    echo "  ✓ No Gateway API CRDs found"
fi
echo ""

# Clean up any orphaned PVCs (they can persist after namespace deletion)
echo "Step 12: Cleaning up orphaned persistent volumes..."
kubectl delete pv --all --ignore-not-found=true 2>/dev/null || {
    echo "  ⚠ Warning: Failed to delete some persistent volumes (continuing anyway)"
}
echo "  ✓ Persistent volumes cleaned up"
echo ""

echo "========================================"
echo "  Cleanup Complete!"
echo "========================================"
echo ""
echo "All resources have been removed from the cluster, including:"
echo "  - Application namespaces and workloads"
echo "  - Linkerd service mesh (namespaces and CRDs)"
echo "  - Traefik ingress controller (Helm release and CRDs)"
echo "  - Gateway API CRDs"
echo "  - Persistent volumes and data"
echo ""
echo "Note: The following were NOT removed:"
echo "  - K3s cluster itself"
echo "  - Other system components in kube-system namespace"
echo ""
echo "To redeploy the stack, run:"
echo "  ./scripts/deploy-all.sh"
echo ""
