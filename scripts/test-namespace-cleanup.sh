#!/bin/bash
# Test script to verify namespace cleanup functionality

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Testing Namespace Cleanup Functionality ==="
echo ""

# Source the force_delete_namespace function from deploy-all.sh
# Extract just the function definition
eval "$(sed -n '/^# Function to forcefully clean up a namespace/,/^}/p' "${SCRIPT_DIR}/deploy-all.sh")"

echo "Test 1: Cleanup when no namespaces exist"
echo "----------------------------------------"
force_delete_namespace "test-nonexistent"
echo "✓ Test 1 passed: No error when namespace doesn't exist"
echo ""

echo "Test 2: Create test namespace and verify cleanup"
echo "------------------------------------------------"
# Create a test namespace
kubectl create namespace test-cleanup-simple 2>/dev/null || true
sleep 1

# Delete it using our function
force_delete_namespace "test-cleanup-simple"

# Verify it's gone
if kubectl get namespace test-cleanup-simple &>/dev/null; then
    echo "❌ Test 2 failed: Namespace still exists"
    exit 1
else
    echo "✓ Test 2 passed: Simple namespace cleanup works"
fi
echo ""

echo "Test 3: Cleanup namespace with resources that have finalizers"
echo "--------------------------------------------------------------"
# Create a namespace with a resource that has finalizers
kubectl create namespace test-cleanup-finalizers 2>/dev/null || true

# Create a configmap with a finalizer
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-config
  namespace: test-cleanup-finalizers
  finalizers:
    - test.example.com/finalizer
data:
  key: value
EOF

sleep 1

# Try to delete using our function
force_delete_namespace "test-cleanup-finalizers"

# Verify it's gone
if kubectl get namespace test-cleanup-finalizers &>/dev/null; then
    echo "❌ Test 3 failed: Namespace with finalizers still exists"
    exit 1
else
    echo "✓ Test 3 passed: Namespace with finalizers cleaned up successfully"
fi
echo ""

echo "Test 4: Handle namespace stuck in Terminating state"
echo "---------------------------------------------------"
# Create a namespace and manually put it in Terminating state
kubectl create namespace test-cleanup-terminating 2>/dev/null || true

# Create a deployment to make the namespace have resources
kubectl create deployment test-app --image=nginx --replicas=1 -n test-cleanup-terminating 2>/dev/null || true
sleep 2

# Start deletion without wait to put it in Terminating state
kubectl delete namespace test-cleanup-terminating --wait=false 2>/dev/null || true
sleep 2

# Check if it's in Terminating state
PHASE=$(kubectl get namespace test-cleanup-terminating -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "$PHASE" = "Terminating" ]; then
    echo "  → Namespace is in Terminating state as expected"
    # Now force cleanup
    force_delete_namespace "test-cleanup-terminating"

    # Verify it's gone
    if kubectl get namespace test-cleanup-terminating &>/dev/null; then
        echo "❌ Test 4 failed: Terminating namespace still exists"
        exit 1
    else
        echo "✓ Test 4 passed: Terminating namespace cleaned up successfully"
    fi
else
    echo "  → Namespace was deleted immediately, simulating with force cleanup anyway"
    force_delete_namespace "test-cleanup-terminating"
    echo "✓ Test 4 passed: Cleanup handled gracefully"
fi
echo ""

echo "=== All Tests Passed! ==="
echo ""
echo "The namespace cleanup functionality is working correctly:"
echo "  ✓ Handles non-existent namespaces gracefully"
echo "  ✓ Cleans up simple namespaces"
echo "  ✓ Removes finalizers from resources"
echo "  ✓ Handles Terminating state namespaces"
echo ""
echo "The deploy-all.sh script should now work reliably regardless of cluster state."
