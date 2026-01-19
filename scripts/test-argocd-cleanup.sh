#!/bin/bash
# Test script to verify ArgoCD application cleanup with finalizers

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Testing ArgoCD Application Cleanup with Finalizers ==="
echo ""

# Source the force_delete_namespace function
eval "$(sed -n '/^# Function to forcefully clean up a namespace/,/^}/p' "${SCRIPT_DIR}/deploy-all.sh")"

echo "Test: Create ArgoCD namespace with application that has finalizers"
echo "-------------------------------------------------------------------"

# Create argocd namespace
kubectl create namespace test-argocd 2>/dev/null || true
sleep 1

# Install ArgoCD CRDs (required for ArgoCD applications)
echo "  → Installing ArgoCD CRDs..."
kubectl apply -k "github.com/argoproj/argo-cd/manifests/crds?ref=stable" > /dev/null 2>&1 || {
    echo "  ⚠ Could not install ArgoCD CRDs from remote, using simplified test"
    echo "  → Creating a custom resource with finalizers instead..."

    # Create a simpler test - just a configmap with a valid finalizer
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-app-config
  namespace: test-argocd
  finalizers:
    - example.com/test-finalizer
data:
  app: test
EOF

    sleep 1

    echo "  → Testing cleanup of namespace with resources with finalizers..."
    force_delete_namespace "test-argocd"

    # Verify it's gone
    if kubectl get namespace test-argocd &>/dev/null; then
        echo "❌ Test failed: Namespace with finalizers still exists"
        exit 1
    else
        echo "✓ Test passed: Namespace with finalizers cleaned up successfully"
    fi

    echo ""
    echo "=== Test Complete ==="
    echo "The cleanup function successfully handles resources with ArgoCD-style finalizers"
    exit 0
}

# If we got here, CRDs installed successfully
# Create a test ArgoCD application with finalizers
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: test-app
  namespace: test-argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/example/repo.git
    targetRevision: HEAD
    path: manifests
  destination:
    server: https://kubernetes.default.svc
    namespace: default
EOF

sleep 2

echo "  → ArgoCD application created with finalizer"
echo "  → Attempting to delete namespace with standard kubectl..."

# Try standard deletion first to show it gets stuck
kubectl delete namespace test-argocd --wait=false 2>/dev/null || true
sleep 3

# Check if it's stuck
PHASE=$(kubectl get namespace test-argocd -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "$PHASE" = "Terminating" ]; then
    echo "  ✓ Namespace stuck in Terminating state as expected (due to finalizer)"
else
    echo "  → Namespace deleted quickly (may not have finalizer blocking)"
fi

echo ""
echo "  → Now using force_delete_namespace function..."
force_delete_namespace "test-argocd"

# Verify it's gone
if kubectl get namespace test-argocd &>/dev/null; then
    echo "❌ Test failed: Namespace still exists after force cleanup"
    kubectl get namespace test-argocd
    exit 1
else
    echo "✓ Test passed: ArgoCD namespace with application finalizers cleaned up successfully"
fi

echo ""
echo "=== Test Complete ==="
echo "The cleanup function successfully handles ArgoCD applications with finalizers"
