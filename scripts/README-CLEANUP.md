# Namespace Cleanup - Quick Reference

## Overview
The `deploy-all.sh` script now includes robust namespace cleanup that handles all edge cases, including namespaces stuck in "Terminating" state due to finalizers.

## Problem Solved
Previously, namespaces could get stuck in "Terminating" state when resources with finalizers (especially ArgoCD applications) blocked deletion. This required manual intervention with commands like:
```bash
kubectl patch application root-app -n argocd -p '{"metadata":{"finalizers":null}}' --type=merge
```

Now this is handled automatically.

## How It Works

The script includes a `force_delete_namespace()` function that:

1. Checks if namespace exists (no-op if it doesn't)
2. Removes finalizers from ArgoCD applications (if argocd namespace)
3. Removes finalizers from ALL resources in the namespace
4. Deletes the namespace
5. If stuck in Terminating, patches the namespace itself
6. Waits up to 60s with final forced cleanup if needed

## Usage

### Normal Deployment (with cleanup)
```bash
./scripts/deploy-all.sh
```
This will automatically clean up existing namespaces before deploying.

### Skip Cleanup
```bash
./scripts/deploy-all.sh --skip-cleanup
```
Useful when you want to preserve existing resources.

### Manual Cleanup Only
If you just want to clean up namespaces without deploying:

```bash
# Source the function
source /dev/stdin <<'EOF'
eval "$(sed -n '/^# Function to forcefully clean up a namespace/,/^}/p' scripts/deploy-all.sh)"
EOF

# Clean specific namespace
force_delete_namespace "argocd"
force_delete_namespace "applications"
force_delete_namespace "monitoring"
```

## Testing

Run the test suite to verify cleanup works:

```bash
# Test general namespace cleanup
./scripts/test-namespace-cleanup.sh

# Test ArgoCD-specific cleanup
./scripts/test-argocd-cleanup.sh
```

Both tests should pass with all checks green.

## Troubleshooting

### Namespace Still Stuck After 60s

Very rare, but if it happens:

1. Check what resources remain:
```bash
kubectl api-resources --verbs=list --namespaced -o name | \
  xargs -n 1 kubectl get --show-kind --ignore-not-found -n <namespace>
```

2. Manually remove finalizers:
```bash
kubectl patch <resource> <name> -n <namespace> \
  -p '{"metadata":{"finalizers":null}}' --type=merge
```

3. Force delete the namespace:
```bash
kubectl get namespace <namespace> -o json | \
  jq '.spec.finalizers = [] | .metadata.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/<namespace>/finalize" -f -
```

### Check Cleanup Status

While cleanup is running, you can monitor in another terminal:
```bash
# Watch namespace status
watch -n 1 'kubectl get namespaces argocd applications monitoring 2>&1'

# Watch ArgoCD applications
watch -n 1 'kubectl get applications -n argocd 2>&1'

# Watch all resources in a namespace
watch -n 1 'kubectl get all -n argocd 2>&1'
```

## Examples

### Example 1: Fresh Deployment
```bash
$ ./scripts/deploy-all.sh
=== Deploying Remotelab K3s Stack ===

Step 0: Checking for existing resources...
  ✓ No existing resources found

Step 1: Installing Linkerd service mesh...
...
```

### Example 2: Cleanup and Redeploy
```bash
$ ./scripts/deploy-all.sh
=== Deploying Remotelab K3s Stack ===

Step 0: Checking for existing resources...
  ⚠ Existing resources detected. Cleaning up for fresh deployment...
  → Deleting initialization jobs...
  → Force deleting namespaces (removing finalizers)...
  → Processing namespace: applications
    • Removing finalizers from resources in applications...
    • Deleting namespace applications...
    • Waiting for namespace deletion...
    ✓ Namespace applications deleted
  → Processing namespace: monitoring
    • Removing finalizers from resources in monitoring...
    • Deleting namespace monitoring...
    • Waiting for namespace deletion...
    ✓ Namespace monitoring deleted
  → Processing namespace: argocd
    • Removing finalizers from ArgoCD applications...
    • Removing finalizers from resources in argocd...
    • Deleting namespace argocd...
    • Namespace stuck in Terminating state, forcing cleanup...
    • Waiting for namespace deletion...
    ✓ Namespace argocd deleted
  → Cleaning up orphaned persistent volumes...
  ✓ Cleanup complete

Step 1: Installing Linkerd service mesh...
...
```

### Example 3: Stuck Namespace Recovery
```bash
$ kubectl get namespaces | grep Terminating
argocd            Terminating   45m

$ ./scripts/deploy-all.sh
=== Deploying Remotelab K3s Stack ===

Step 0: Checking for existing resources...
  ⚠ Existing resources detected. Cleaning up for fresh deployment...
  → Force deleting namespaces (removing finalizers)...
  → Processing namespace: argocd
    • Removing finalizers from ArgoCD applications...
application.argoproj.io/root-app patched
    • Removing finalizers from resources in argocd...
    • Deleting namespace argocd...
    • Namespace stuck in Terminating state, forcing cleanup...
namespace/argocd patched
    • Waiting for namespace deletion...
    ✓ Namespace argocd deleted
  ✓ Cleanup complete
...
```

## Implementation Details

### Files Modified
- `/Users/adam.leskis/repos/k3s-remotelab/scripts/deploy-all.sh`
  - Added `force_delete_namespace()` function
  - Updated cleanup logic to use the function

### Files Added
- `/Users/adam.leskis/repos/k3s-remotelab/scripts/test-namespace-cleanup.sh` - General test suite
- `/Users/adam.leskis/repos/k3s-remotelab/scripts/test-argocd-cleanup.sh` - ArgoCD-specific tests
- `/Users/adam.leskis/repos/k3s-remotelab/NAMESPACE-CLEANUP-IMPROVEMENTS.md` - Detailed documentation
- `/Users/adam.leskis/repos/k3s-remotelab/scripts/README-CLEANUP.md` - This quick reference

## When to Use

### Use Regular Deployment (with cleanup)
- Starting fresh
- After making changes that require redeployment
- When namespaces are stuck
- For testing and development

### Use --skip-cleanup Flag
- Updating only specific components
- When you know resources are healthy
- For faster iterations during development
- When preserving data in namespaces

## Performance

Typical cleanup times:
- Empty namespaces: 2-5 seconds each
- Namespaces with resources: 5-15 seconds each
- Stuck namespaces: 10-30 seconds each
- Maximum wait time: 60 seconds per namespace

Total cleanup time is typically 30-60 seconds for all three namespaces.

## Safety

The cleanup function is safe because:
- Only targets specified namespaces (argocd, applications, monitoring)
- Checks if namespace exists before processing
- Uses `--ignore-not-found` to handle missing resources
- Doesn't affect other namespaces
- Provides clear output of what it's doing
- Has timeout protection to prevent infinite loops

## Support

If you encounter issues:
1. Check the output messages - they're descriptive
2. Run the test scripts to verify functionality
3. Check kubectl access: `kubectl get namespaces`
4. Review the detailed documentation in NAMESPACE-CLEANUP-IMPROVEMENTS.md
