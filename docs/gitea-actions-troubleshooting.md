# Gitea Actions Runner Troubleshooting

## Overview
This document describes the Gitea Actions runner setup and common troubleshooting steps.

## Architecture
- **Gitea**: Version 1.22.6 (upgraded from 1.20.6 for runner compatibility)
- **Runner**: `gitea/act_runner:nightly-dind-rootless` (Docker-in-Docker rootless mode)
- **Runner Name**: k3s-runner
- **Labels**: ubuntu-latest, ubuntu-24.04, ubuntu-22.04

## Common Issues and Solutions

### Issue 1: Workflows Stuck in "Waiting" Status

**Symptoms:**
- Workflows show "Waiting" in Gitea UI with 0s duration
- No runner picking up jobs

**Root Cause:**
Runner registration token is invalid or runner not properly registered with Gitea.

**Solution:**
1. Check if runner pod is running:
   ```bash
   kubectl get pods -n applications -l app=act-runner
   ```

2. Check runner logs for errors:
   ```bash
   kubectl logs -n applications -l app=act-runner --tail=50
   ```

3. Look for registration errors like:
   - "runner token not found"
   - "Your Gitea version is too old to support runner declare"

4. Regenerate the runner token:
   ```bash
   ./scripts/regenerate-gitea-runner-token.sh
   ```

### Issue 2: Runner Pod in CrashLoopBackOff

**Symptoms:**
- Runner pod status shows "CrashLoopBackOff" or "Error"
- Logs show: "Your Gitea version is too old to support runner declare, please upgrade to v1.21 or later"

**Root Cause:**
Gitea version incompatibility. The act_runner requires Gitea 1.21 or later.

**Solution:**
Upgrade Gitea to version 1.21 or later (current: 1.22):
```bash
# Edit manifests/applications/gitea.yaml
# Change image from gitea/gitea:1.20 to gitea/gitea:1.22
kubectl apply -f manifests/applications/gitea.yaml
kubectl rollout status deployment/gitea -n applications
```

### Issue 3: Runner Registered but Not Executing Jobs

**Symptoms:**
- Runner logs show "declare successfully"
- Jobs still stuck in "Waiting"

**Troubleshooting:**
1. Check runner labels match workflow requirements:
   ```bash
   kubectl logs -n applications -l app=act-runner | grep "declare successfully"
   # Should show: runner: k3s-runner, with labels: [ubuntu-latest ubuntu-24.04 ubuntu-22.04]
   ```

2. Verify workflow file uses compatible labels:
   ```yaml
   runs-on: ubuntu-latest  # or ubuntu-22.04, ubuntu-24.04
   ```

3. Check Gitea Actions configuration in Gitea UI:
   - Settings > Actions > Runners
   - Should show "k3s-runner" as online

## Manual Runner Token Generation

If the script fails, generate token manually:

```bash
# Generate token from Gitea CLI
kubectl exec -n applications deployment/gitea -c gitea -- \
  su -c "/usr/local/bin/gitea actions generate-runner-token" git

# Update the secret with the new token
kubectl patch secret -n applications runner-secret \
  -p '{"stringData":{"token":"YOUR_TOKEN_HERE"}}'

# Restart runner pod
kubectl delete pod -n applications -l app=act-runner
```

## Verifying Runner Status

1. Check runner registration:
   ```bash
   kubectl logs -n applications -l app=act-runner --tail=20
   ```
   Look for: "runner: k3s-runner, with version: ..., declare successfully"

2. Check if runner is picking up tasks:
   ```bash
   kubectl logs -n applications -l app=act-runner --tail=50
   ```
   Look for: "task N repo is ..."

3. Check in Gitea UI:
   - Navigate to repository > Settings > Actions > Runners
   - Should show runner as "online"

## Configuration Files

- **Gitea Deployment**: `manifests/applications/gitea.yaml`
- **Runner Deployment**: `manifests/applications/gitea-actions-runner.yaml`
- **Runner Secret**: Created by runner manifest, contains registration token
- **Token Regeneration Script**: `scripts/regenerate-gitea-runner-token.sh`

## Known Limitations

1. Runner uses rootless Docker-in-Docker mode (no privileged containers)
2. Runner token must be regenerated if:
   - Gitea is reinstalled/reset
   - Token expires (current tokens don't expire)
   - Runner registration is deleted from Gitea

## Recent Fixes (2026-01-08)

1. Upgraded Gitea from 1.20.6 to 1.22.6 for runner compatibility
2. Generated valid runner registration token using Gitea CLI
3. Updated runner-secret with valid token
4. Restarted runner pod to register with Gitea 1.22
5. Verified runner successfully picks up and executes workflow jobs
