# Homelab Deployment Scripts

This directory contains scripts to set up and deploy your K3s homelab.

## Scripts

### `install-k3s.sh`
System-level installation script for K3s.

**Purpose:**
- Installs K3s with homelab-optimized configuration
- Sets up kubectl access
- Installs Helm
- Configures storage and Traefik ingress

**Usage:**
```bash
./scripts/install-k3s.sh
```

**Run this once** before deploying the stack. Requires sudo access.

### `deploy-all.sh`
Complete deployment script for the entire homelab stack.

**Purpose:**
- Fully automated, non-interactive deployment
- Idempotent with automatic cleanup
- No sudo required (except for K3s installation)
- No persistent Docker configuration changes
- Builds and pushes images to Gitea registry

**Usage:**
```bash
# Standard deployment (fully automated)
./scripts/deploy-all.sh

# Skip cleanup to preserve existing resources
./scripts/deploy-all.sh --skip-cleanup

# Show help
./scripts/deploy-all.sh --help
```

**What it does:**
0. Checks for existing resources and cleans them up (can be skipped with `--skip-cleanup`)
1. Deploys namespaces, ArgoCD, and monitoring stack
2. Deploys infrastructure (PostgreSQL, Redis, Gitea)
3. Configures ingress with container registry support
4. **Automatically creates Gitea admin user** (homelab/homelab)
5. **Uses temporary Docker config** for insecure registry (no system changes!)
6. Builds Django image and pushes to Gitea registry
7. Deploys Django application
8. Cleans up temporary configuration

**Key Features:**
- ✅ **Fully automated** - no user prompts or interaction
- ✅ **No sudo required** - runs with user permissions
- ✅ **Non-invasive** - temporary Docker config, no persistent changes
- ✅ **Idempotent** - safe to run multiple times
- ✅ **Portable** - works in ephemeral environments (CI/CD, remote labs)
- ✅ **Laptop-friendly** - doesn't modify your local Docker config

## Quick Start

```bash
# 1. Install K3s (one-time setup)
./scripts/install-k3s.sh

# 2. Deploy the entire stack
./scripts/deploy-all.sh

# 3. Access services at http://localhost/<service-name>
```

## Prerequisites

- Ubuntu/Debian Linux (tested on Ubuntu 20.04+)
- At least 4GB RAM
- Docker installed and running
- Sudo access for K3s installation only

**No Docker configuration needed!** The deployment script uses a temporary Docker config that doesn't require any system changes.

## Post-Deployment

After running `deploy-all.sh`, you can:
- Access Gitea at http://localhost/gitea and create a user
- Push images to the container registry at localhost
- Use ArgoCD for GitOps deployments
- Monitor with Prometheus/Grafana

See `docs/CONTAINER_REGISTRY_SETUP.md` for detailed registry setup.
