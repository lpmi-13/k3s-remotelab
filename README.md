# Argo GitOps Failure Lab

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
| **Missing ConfigMap** | Deployment references a non-existent ConfigMap | Restore the ConfigMap reference |
| **SOPS Decrypt Failure** | SOPS age data-key block corrupted in encrypted secrets file | Restore the encrypted file or re-encrypt it |
| **HMAC Mismatch** | Ciphertext tampered without updating MAC | Re-encrypt the secrets file with valid data |
| **Wrong Type in SOPS** | Encrypted `secrets` value is randomized to a wrong shape | Re-encrypt the file with `secrets` as a valid env-var map |
| **Stuck Sync** | Health check path changed to non-existent endpoint, pods never become Ready | Fix the health check path in values.yaml |
| **Stale Job** | PreSync migration Job template changed so the hook fails before sync | Restore the migration Job command and re-sync |
| **Orphaned Resource** | Deployment/Service renamed, old resources remain (prune disabled) | Delete orphaned resources via ArgoCD UI |

The Wrong Type in SOPS scenario chooses a variant at injection time: `secrets`
may be replaced with a string, list, int, or an invalid map shape such as a bad
environment variable name.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Local K3s Cluster                    │
│                                                         │
│  ┌──────────┐    watches     ┌──────────────────────┐   │
│  │ Scenario │───────────────>│   ArgoCD             │   │
│  │Controller│                │   (Application CR)   │   │
│  └─────┬────┘                └──────────┬───────────┘   │
│        │ pushes                         │ syncs         │
│        │ bad commits                    │               │
│        v                                v               │
│  ┌──────────┐                ┌──────────────────────┐   │
│  │  Gitea   │<───────────────│   Django App         │   │
│  │  (Git)   │   helm chart   │   (Deployment,       │   │
│  └──────────┘   + SOPS       │    ConfigMap,        │   │
│                  secrets     │    Service, Job)     │   │
│                              └──────────────────────┘   │
│                                                         │
│  Backing services: PostgreSQL                           │
│  Ingress: Traefik (path-based routing)                  │
└─────────────────────────────────────────────────────────┘
```

- **ArgoCD** - GitOps controller, syncs Helm chart from Gitea to cluster
- **Gitea** - Local Git server (no CI, no registry, git-only)
- **Django** - Target application image built locally or published to GHCR
- **Scenario Controller** - Go binary that injects failures and monitors recovery
- **SOPS/age** - Secrets encryption (helm-secrets plugin on ArgoCD repo-server)
- **Traefik** - Ingress controller with path-based routing

## Run Locally After Cloning

### Prerequisites

| Tool | macOS Install | Purpose |
|------|---------------|---------|
| Colima | `brew install colima` | Lightweight VM with k3s |
| kubectl | `brew install kubectl` | Kubernetes CLI |
| age | `brew install age` | Encryption key generation |
| sops | `brew install sops` | Secrets encryption |
| Helm | `brew install helm` | Required for Traefik install |

On Linux, you need k3s installed directly (no Colima needed), plus `age`, `sops`, and `helm`.
Initial Linux setup needs `sudo` for k3s installation and may prompt again during `deploy-all.sh` if the script has to repair `/etc/rancher/k3s/config.yaml`, restart k3s, or import the locally built scenario-controller image into k3s containerd. Normal lab use after deployment is through `kubectl`, ArgoCD, and git access to the internal Gitea service and does not require `sudo`.

### Clone And Deploy

```bash
git clone https://github.com/lpmi-13/argo-remotelab.git
cd argo-remotelab
bash scripts/deploy-all.sh
```

This takes about 5-10 minutes and:
1. Starts Colima with k3s (or verifies existing k3s on Linux)
2. Installs the pinned ArgoCD v3.3.7 manifest with SOPS/helm-secrets support
3. Generates age encryption keys
4. Deploys PostgreSQL and Gitea
5. Pushes the Django Helm chart to Gitea with encrypted secrets
6. Creates the ArgoCD Application
7. Builds and deploys the scenario controller
8. Waits for everything to be healthy

### Local Access

| Service | URL | Credentials |
|---------|-----|-------------|
| ArgoCD | https://localhost/argocd | admin / remotelab |
| Django | https://localhost/django/api/health/ | - |

Accept the self-signed certificate warning in your browser.
The deploy script patches ArgoCD's admin password to `remotelab` directly and
restarts `argocd-server`; deployment fails if that password cannot be applied.

### Local Cleanup

```bash
bash scripts/cleanup-all.sh
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
description: Corrupts the age-encrypted SOPS data key...
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

Most fixes involve editing the Helm chart in the internal Gitea git repository. No Gitea browser UI is required for the learner path.

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
- Or use kubectl, for example:
  `kubectl delete job <name> -n applications` or
  `kubectl delete deployment django-web -n applications`
- If a failed hook sync keeps retrying after the git fix, terminate the running
  ArgoCD operation in the UI, or patch the Application with:
  `kubectl patch application django-app -n argocd --type=merge -p '{"operation":null}'`

### After a Fix

The controller detects the app is healthy again and logs the explanation:

```
application is Healthy and Synced again!
=== SCENARIO EXPLANATION: sops-decrypt-failure ===
what happened: The age-encrypted SOPS data key in secrets.yaml.enc was corrupted...
how to fix: Re-encrypt the file or restore the encrypted file from history...
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
│   ├── applications/          # Gitea, PostgreSQL, scenario controller
│   ├── gitops/                # Pinned ArgoCD install, SOPS setup, ingress
│   └── infrastructure/        # Traefik ingress rules
├── sample-django-app/
│   ├── app/                   # Django runtime image source
│   ├── Dockerfile             # Runtime image build
│   └── chart/django-app/      # Helm chart (pushed to Gitea at deploy)
│       ├── templates/         # Deployment, Service, ConfigMap, Job
│       ├── values.yaml        # App configuration
│       └── .sops.yaml         # SOPS encryption rules
├── scenario-controller/       # Go source for the failure injector
│   ├── cmd/main.go            # Main loop
│   ├── internal/argocd/       # K8s dynamic client for Application CR
│   ├── internal/git/          # Git clone/modify/push via os/exec
│   ├── internal/scenarios/    # 7 scenario implementations
│   └── Dockerfile             # Multi-stage build
├── scripts/
│   ├── deploy-all.sh          # Full deployment script
│   ├── deploy-preloaded-vm.sh # iximiuz/preloaded VM deployment path
│   ├── build-rootfs-image.sh  # Build iximiuz rootfs image
│   ├── cleanup-all.sh         # Teardown script
│   ├── update-version-refs.sh # Keep image tag references aligned
│   └── lib/platform.sh        # Platform detection utilities
├── playground/iximiuz/        # iximiuz manifest, rootfs Dockerfile, bootstrap unit
└── secrets/keys/              # Generated age keys (gitignored)
```

## Platform Support

| Platform | Kubernetes | Notes |
|----------|-----------|-------|
| macOS (Apple Silicon / Intel) | Colima + k3s | Primary dev platform |
| Linux (Ubuntu/Debian) | Native k3s | Requires sudo for initial host setup |

### macOS Setup

```bash
brew install colima kubectl age sops helm
colima start --kubernetes --runtime containerd --cpu 4 --memory 6 --disk 60
```

### Linux Setup

```bash
# Install k3s
curl -sfL https://get.k3s.io | sudo sh -

# Install tools
sudo apt install age
# Install sops and helm manually (see their GitHub releases)
```

The privileged Linux steps are mostly host setup: k3s installation, occasional k3s advertised-IP repair if your host IP changes, and local image import when Docker is used as the fallback builder. If `nerdctl` is installed and can build into the k3s/containerd namespace, `deploy-all.sh` can avoid the Docker `save | sudo k3s ctr images import` fallback. Re-running the lab after it is deployed should only require unprivileged `kubectl` commands unless you rebuild/redeploy the controller image or reset k3s.

## Build, Push, And Publish

The iximiuz path bakes the lab files and required container images into a k3s-capable rootfs image. The bootstrap unit imports the image archive into k3s containerd, runs `scripts/deploy-preloaded-vm.sh`, and only lets the playground init task finish after the first scenario has been injected and detected by ArgoCD.

This path requires Docker, GHCR push access, and `labctl`.

Pick one version tag — `IMAGE_TAG` is applied to both the app images and the rootfs image:

```bash
export IMAGE_TAG=v2

docker login ghcr.io
PUSH_IMAGES=1 bash scripts/build-rootfs-image.sh
```

The build script creates/pushes:
- `ghcr.io/lpmi-13/argo-remotelab-scenario-controller:${IMAGE_TAG}`
- `ghcr.io/lpmi-13/argo-remotelab-argocd-tools:${IMAGE_TAG}`
- `ghcr.io/lpmi-13/argo-remotelab-django:${IMAGE_TAG}`
- `ghcr.io/lpmi-13/argo-remotelab-k3s-rootfs:${IMAGE_TAG}`

Set `ROOTFS_IMAGE` only if you need to push the rootfs to a different registry or repo than the default.

After a successful build, the script also rewrites `playground/iximiuz/manifest.yaml` so its rootfs drive points at the new `oci://...` reference. Verify that before publishing the playground:

```bash
grep -n "source: oci://" playground/iximiuz/manifest.yaml
```

> NB: you will also need to update the visibility of the images in your packages settings to `public` so that the iximiuz platform can actually pull them.

Create or update the iximiuz custom playground from that manifest:

```bash
labctl auth login

# First publish
labctl playground create argo-remotelab-3bf4e8fb \
  --base flexbox \
  --file playground/iximiuz/manifest.yaml

# Later updates
labctl playground update argo-remotelab-3bf4e8fb \
  --file playground/iximiuz/manifest.yaml \
  --force
```

> The above UUIDs (ie, `3bf4e8fb` at the end of the playground name are autogenerated by the system so are included above for reference, but if you create one, they will be different.

Start it from iximiuz or with `labctl playground start argo-remotelab-3bf4e8fb`. The ArgoCD tab should not become ready until the init task sees the first injected failure marker inside the VM.

## Configuration

The scenario controller is configured via environment variables in `manifests/applications/scenario-controller.yaml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `MIN_DELAY_SECONDS` | 0 | Minimum wait (seconds) between healthy detection and injection |
| `MAX_DELAY_SECONDS` | 0 | Maximum wait (seconds) before injection (0 = inject immediately) |
| `FIRST_SCENARIO` | sops-decrypt-failure,hmac-mismatch,wrong-type-sops | Comma-separated pool the very first injection is picked from at random; later runs are fully random. Empty = always random. The default lists the three render-time SOPS failures, which all detect within seconds of the next ArgoCD refresh. |
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
