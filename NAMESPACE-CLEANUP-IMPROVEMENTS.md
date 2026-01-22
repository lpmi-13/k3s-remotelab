# Namespace Cleanup Improvements

## Problem
The `deploy-all.sh` script was getting stuck when trying to delete namespaces because resources with finalizers (like ArgoCD applications) were blocking deletion. This could cause namespaces to get stuck in "Terminating" state indefinitely.

## Solution
Added a robust `force_delete_namespace()` function that handles namespace cleanup in all scenarios:

### What the Function Does

1. **Removes ArgoCD Application Finalizers**: Before deleting the argocd namespace, it removes finalizers from all ArgoCD applications that would block deletion.

2. **Removes All Resource Finalizers**: Iterates through all resource types in the namespace and removes their finalizers.

3. **Handles Terminating State**: If a namespace gets stuck in "Terminating" state, it patches the namespace itself to remove finalizers.

4. **Graceful Timeout Handling**: Waits up to 60 seconds for deletion, with a final forced cleanup via the Kubernetes API if needed.

5. **No-op for Non-existent Resources**: Safely handles cases where namespaces or resources don't exist.

### Key Features

- **Idempotent**: Can be run multiple times safely
- **Robust**: Handles all common blocking scenarios
- **Non-destructive**: Only removes finalizers from resources being deleted
- **Informative**: Provides clear progress output during cleanup
- **Fast**: Parallel operations where possible

## Changes Made

### File: `/Users/adam.leskis/repos/k3s-remotelab/scripts/deploy-all.sh`

1. Added `force_delete_namespace()` function (lines 47-125)
   - Comprehensive documentation comment
   - Handles all edge cases
   - Provides detailed progress output

2. Updated cleanup section (lines 120-159)
   - Replaced simple `kubectl delete` with `force_delete_namespace()` calls
   - Processes namespaces in reverse dependency order: applications → monitoring → argocd

### Testing

Created comprehensive test suite: `/Users/adam.leskis/repos/k3s-remotelab/scripts/test-namespace-cleanup.sh`

Tests verify:
- Non-existent namespace handling
- Simple namespace cleanup
- Resources with finalizers
- Namespaces stuck in Terminating state

All tests pass successfully.

## Verification

### Test Scenarios

The updated script now handles these scenarios reliably:

#### Scenario 1: Fresh Start (No Namespaces)
```bash
./scripts/deploy-all.sh
```
Expected: No errors, skips cleanup, proceeds with deployment

#### Scenario 2: Healthy Existing Namespaces
```bash
# Deploy once
./scripts/deploy-all.sh

# Deploy again (triggers cleanup)
./scripts/deploy-all.sh
```
Expected: Cleanly removes all resources and namespaces, redeploys successfully

#### Scenario 3: Namespaces Stuck in Terminating
```bash
# If namespaces are stuck:
kubectl get namespaces | grep Terminating

# Run deployment
./scripts/deploy-all.sh
```
Expected: Forces cleanup of stuck namespaces, proceeds with deployment

### Manual Verification

To verify the fix works with stuck namespaces:

```bash
# Check current namespace status
kubectl get namespaces

# If any are stuck in Terminating, run:
./scripts/deploy-all.sh

# Verify all target namespaces are gone or recreated:
kubectl get namespaces argocd applications monitoring
```

## How It Works

### Before (Old Code)
```bash
kubectl delete namespace argocd --ignore-not-found=true --wait=false
# Could get stuck if ArgoCD applications have finalizers
```

### After (New Code)
```bash
force_delete_namespace "argocd"
# 1. Removes finalizers from ArgoCD applications
# 2. Removes finalizers from all resources in namespace
# 3. Deletes namespace
# 4. If stuck in Terminating, patches namespace itself
# 5. Waits for completion with timeout handling
```

## Benefits

1. **Always Works**: The script can now recover from any namespace state
2. **Faster Cleanup**: No more waiting indefinitely for stuck namespaces
3. **Better Feedback**: Clear progress messages during cleanup
4. **Production Ready**: Handles real-world scenarios gracefully

## Implementation Details

### Finalizer Removal Strategy

The function uses a multi-layered approach:

1. **Application Level**: Removes ArgoCD application finalizers first (most common blocker)
2. **Resource Level**: Removes finalizers from all resources in the namespace
3. **Namespace Level**: Patches the namespace itself if stuck
4. **API Level**: Uses direct API calls as a last resort

### Performance

- Processes resources in parallel where possible
- Uses `--wait=false` to avoid blocking
- 2-second polling interval for namespace deletion
- 60-second timeout with fallback to forced deletion

### Error Handling

- All operations use `|| true` to prevent script failures
- Checks namespace existence before processing
- Provides warnings if manual intervention is needed
- Returns success (0) or failure (1) status codes

## Future Improvements

Potential enhancements:
- Add `--force` flag to skip cleanup confirmation
- Add `--cleanup-only` flag to only run cleanup
- Add cleanup status report (what was deleted)
- Add cleanup dry-run mode

## Related Files

- Main script: `/Users/adam.leskis/repos/k3s-remotelab/scripts/deploy-all.sh`
- Test suite: `/Users/adam.leskis/repos/k3s-remotelab/scripts/test-namespace-cleanup.sh`
- Platform utilities: `/Users/adam.leskis/repos/k3s-remotelab/scripts/lib/platform.sh`
