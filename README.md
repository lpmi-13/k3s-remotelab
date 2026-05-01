# GitOps Failure Lab

A hands-on ArgoCD troubleshooting environment that randomly injects realistic GitOps failures into a running application. You diagnose and fix each issue using the ArgoCD UI and kubectl, then the system explains what went wrong and moves on to the next challenge.

## How It Works

1. A Django application is deployed via ArgoCD from a Helm chart stored in Gitea
2. Secrets are encrypted with SOPS/age and decrypted at sync time by helm-secrets
3. A scenario controller watches the ArgoCD Application health status
4. When the app is healthy, the controller waits a random interval then injects a failure by pushing a malicious commit to Gitea
5. ArgoCD detects the drift and the app becomes unhealthy/out-of-sync
6. You troubleshoot and fix the issue using ArgoCD UI + kubectl
7. Once fixed, the controller logs an explanation of what happened and the cycle repeats

## Failure Scenarios

| Scenario | What Breaks | How to Fix |
|----------|-------------|------------|
| **Missing ConfigMap** | `appConfig.enabled` set to false, ConfigMap disappears but Deployment still references it | Re-enable the ConfigMap in values.yaml |
| **SOPS Decrypt Failure** | SOPS metadata block removed from encrypted secrets file | Restore the sops metadata or re-encrypt the file |
| **HMAC Mismatch** | Ciphertext tampered without updating MAC | Re-encrypt the secrets file with valid data |
| **Wrong Type in SOPS** | Integer value where string expected (e.g. `DB_PORT: 5432` vs `"5432"`) | Fix the type in the encrypted values |
| **Stuck Sync** | Health check path changed to non-existent endpoint, pods never become Ready | Fix the health check path in values.yaml |
| **Stale Job** | Immutable Job spec modified, ArgoCD can't update it | Delete the old Job via ArgoCD UI or kubectl |
| **Orphaned Resource** | Deployment/Service renamed, old resources remain (prune disabled) | Delete orphaned resources via ArgoCD UI |
| **PVC Incompatible** | PostgreSQL major version changed, data files incompatible | Revert the image version or delete the PVC |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Local K3s Cluster                      │
│                                                          │
│  ┌──────────┐    watches     ┌──────────────────────┐   │
│  │ Scenario │───────────────>│   ArgoCD             │   │
│  │Controller│                │   (Application CR)   │   │
│  └─────┬────┘                └──────────┬───────────┘   │
│        │ pushes                          │ syncs         │
│        │ bad commits                     │               │
│        v                                 v               │
│  ┌──────────┐                ┌──────────────────────┐   │
│  │  Gitea   │<───────────────│   Django App         │   │
│  │  (Git)   │   helm chart   │   (Deployment,       │   │
│  └──────────┘   + SOPS       │    ConfigMap,         │   │
│                  secrets      │    Service, Job)      │   │
│                               └──────────────────────┘   │
│                                                          │
│  Backing services: PostgreSQL, Redis                     │
│  Ingress: Traefik (path-based routing)                   │
└─────────────────────────────────────────────────────────┘
```

- **ArgoCD** - GitOps controller, syncs Helm chart from Gitea to cluster
- **Gitea** - Local Git server (no CI, no registry, git-only)
- **Django** - Target application (pre-built image from GHCR)
- **Scenario Controller** - Go binary that injects failures and monitors recovery
- **SOPS/age** - Secrets encryption (helm-secrets plugin on ArgoCD repo-server)
- **Traefik** - Ingress controller with path-based routing

## Quick Start

### Prerequisites

| Tool | macOS Install | Purpose |
|------|---------------|---------|
| Colima | `brew install colima` | Lightweight VM with k3s |
| kubectl | `brew install kubectl` | Kubernetes CLI |
| age | `brew install age` | Encryption key generation |
| sops | `brew install sops` | Secrets encryption |
| Helm | `brew install helm` | Required for Traefik install |

On Linux, you need k3s installed directly (no Colima needed), plus `age`, `sops`, and `helm`.

### Deploy

```bash
./scripts/deploy-all.sh
```

This takes about 5-10 minutes and:
1. Starts Colima with k3s (or verifies existing k3s on Linux)
2. Installs ArgoCD with SOPS/helm-secrets support
3. Generates age encryption keys
4. Deploys PostgreSQL, Redis, and Gitea
5. Pushes the Django Helm chart to Gitea with encrypted secrets
6. Creates the ArgoCD Application
7. Builds and deploys the scenario controller
8. Waits for everything to be healthy

### Access

| Service | URL | Credentials |
|---------|-----|-------------|
| ArgoCD | https://localhost/argocd | admin / remotelab |
| Gitea | https://localhost/gitea | remotelab / remotelab |
| Django | https://localhost/django/api/health/ | - |

Accept the self-signed certificate warning in your browser.

### Cleanup

```bash
./scripts/cleanup-all.sh
```

## Workflow

Once deployed, the scenario controller logs its activity:

```bash
# Watch the controller in real-time
kubectl logs -n applications deployment/scenario-controller -f
```

You'll see:
```
waiting for ArgoCD application to be Healthy and Synced...
application is Healthy and Synced
waiting 2m30s before injecting next scenario...
=== INJECTING SCENARIO: sops-decrypt-failure ===
description: Removes the sops metadata block from the encrypted secrets file...
scenario "sops-decrypt-failure" injected successfully, pushed to git
waiting for user to fix the issue (app must return to Healthy + Synced)...
```

### Diagnosing Issues

```bash
# Check ArgoCD Application status
kubectl get applications -n argocd django-app

# See sync errors and conditions
kubectl get applications -n argocd django-app -o jsonpath='{.status.conditions}' | jq .

# Check ArgoCD repo-server logs (SOPS/render errors show here)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=50

# Check pod status
kubectl get pods -n applications

# Describe failing pods
kubectl describe pod -n applications -l app=django
```

### Fixing Issues

Most fixes involve editing the Helm chart in Gitea:

```bash
# Clone the repo locally (port-forward first)
kubectl port-forward svc/gitea -n applications 3000:3000 &
git clone http://remotelab:remotelab@localhost:3000/remotelab/django-app.git /tmp/fix
cd /tmp/fix

# Make your fix (e.g., restore values.yaml)
vi chart/django-app/values.yaml

# For SOPS-encrypted files, use sops to edit
export SOPS_AGE_KEY_FILE=path/to/secrets/keys/local.key
sops chart/django-app/secrets.yaml.enc

# Push the fix
git add -A && git commit -m "fix: restore broken config" && git push
```

ArgoCD will automatically detect the change and re-sync.

For scenarios requiring resource deletion (stale Job, orphaned resources):
- Use the ArgoCD UI to delete specific resources
- Or use kubectl: `kubectl delete job <name> -n applications`

### After a Fix

The controller detects the app is healthy again and logs the explanation:

```
application is Healthy and Synced again!
=== SCENARIO EXPLANATION: sops-decrypt-failure ===
what happened: The sops metadata block was removed from secrets.yaml.enc...
how to fix: Re-encrypt the file or restore the sops metadata block...
diagnostic commands:
  $ kubectl get applications -n argocd django-app -o jsonpath='{.status.conditions}'
  $ kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=50
```

Then it waits another random interval before injecting the next failure.

## Directory Structure

```
├── argocd-apps/               # ArgoCD Application definition
│   └── django-app.yaml        # Points at Gitea repo, uses helm-secrets
├── manifests/
│   ├── applications/          # Gitea, PostgreSQL, Redis, scenario controller
│   ├── gitops/                # ArgoCD config, SOPS setup, ingress
│   └── infrastructure/        # Traefik ingress rules
├── sample-django-app/
│   └── chart/django-app/      # Helm chart (pushed to Gitea at deploy)
│       ├── templates/         # Deployment, Service, ConfigMap, Job
│       ├── values.yaml        # App configuration
│       └── .sops.yaml         # SOPS encryption rules
├── scenario-controller/       # Go source for the failure injector
│   ├── cmd/main.go            # Main loop
│   ├── internal/argocd/       # K8s dynamic client for Application CR
│   ├── internal/git/          # Git clone/modify/push via os/exec
│   ├── internal/scenarios/    # 8 scenario implementations
│   └── Dockerfile             # Multi-stage build
├── scripts/
│   ├── deploy-all.sh          # Full deployment script
│   ├── cleanup-all.sh         # Teardown script
│   └── lib/platform.sh        # Platform detection utilities
└── secrets/keys/              # Generated age keys (gitignored)
```

## Platform Support

| Platform | Kubernetes | Notes |
|----------|-----------|-------|
| macOS (Apple Silicon / Intel) | Colima + k3s | Primary dev platform |
| Linux (Ubuntu/Debian) | Native k3s | Requires sudo for k3s install |

### macOS Setup

```bash
brew install colima kubectl age sops helm
colima start --kubernetes --runtime containerd --cpu 4 --memory 6 --disk 60
```

### Linux Setup

```bash
# Install k3s
curl -sfL https://get.k3s.io | sh -

# Install tools
sudo apt install age
# Install sops and helm manually (see their GitHub releases)
```

## Configuration

The scenario controller is configured via environment variables in `manifests/applications/scenario-controller.yaml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `MIN_DELAY_SECONDS` | 0 | Minimum wait (seconds) between healthy detection and injection |
| `MAX_DELAY_SECONDS` | 0 | Maximum wait (seconds) before injection (0 = inject immediately) |
| `ARGOCD_APP_NAME` | django-app | ArgoCD Application to monitor |
| `GITEA_URL` | http://gitea... | Internal Gitea service URL |

## Troubleshooting the Lab Itself

### ArgoCD Can't Decrypt Secrets

Check repo-server logs:
```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=50
```

Common issues:
- `sops: not found` → SOPS binary not in PATH on repo-server
- `could not decrypt` → Age key mismatch between what encrypted and what's mounted

### Scenario Controller Not Injecting

```bash
kubectl logs -n applications deployment/scenario-controller
```

Common issues:
- Application stuck as "Unknown" sync status (repo-server can't render)
- Controller waiting for Healthy+Synced but app never recovers

### Complete Reset

```bash
./scripts/cleanup-all.sh -y
./scripts/deploy-all.sh
```

## License

MIT
