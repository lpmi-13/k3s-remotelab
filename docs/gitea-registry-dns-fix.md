# Gitea Registry DNS Fix

## Problem

The Gitea Actions workflow was failing with:
```
Error response from daemon: Get "https://gitea:3000/v2/": dial tcp: lookup gitea:3000 on 10.43.0.10:53: no such host
```

The issue was that `gitea:3000` is a fake hostname that only existed in the ingress configuration, not in actual DNS.

## Solution

Changed the workflow and related configurations to use the internal Kubernetes service name `gitea:3000` instead of `gitea:3000`.

### Changes Made

1. **Workflow file** (`sample-django-app/.gitea/workflows/build.yml`):
   - Changed `REGISTRY: gitea:3000` to `REGISTRY: gitea:3000`

2. **Gitea Actions Runner** (`manifests/applications/gitea-actions-runner.yaml`):
   - Added `--insecure-registry=gitea:3000` flag to the DinD (Docker-in-Docker) container
   - This allows the workflow's Docker daemon to push to the registry over HTTP

3. **Django Deployment** (`manifests/applications/django.yaml`):
   - Changed ArgoCD Image Updater annotation from `gitea:3000/remotelab/django-app:1.x` to `gitea:3000/remotelab/django-app:1.x`

4. **ArgoCD Image Updater** (`manifests/gitops/argocd-image-updater.yaml`):
   - Changed registry prefix from `gitea:3000` to `gitea:3000`
   - Changed API URL from `https://gitea:3000/api/v1` to `http://gitea.applications.svc.cluster.local:3000/api/v1`

## How It Works

1. **Within the Cluster**: The service name `gitea:3000` resolves to `gitea.applications.svc.cluster.local:3000` because:
   - The act-runner pod is in the `applications` namespace
   - Kubernetes DNS automatically adds namespace search suffixes
   - The DinD container shares the pod's network namespace

2. **Docker Registry**: The DinD container is configured to accept `gitea:3000` as an insecure registry, allowing HTTP connections.

3. **Image Updater**: ArgoCD Image Updater uses the full service DNS name to query the Gitea API for new image versions.

## K3s Node Configuration (Required for Image Pulling)

When Kubernetes needs to pull images from `gitea:3000`, the container runtime on the node (containerd) needs to be configured. Since `gitea:3000` is a cluster service, there are two approaches:

### Option 1: Use a different registry URL for K8s

The workflow pushes to `gitea:3000`, but the deployment uses a different image reference that K8s can resolve. This requires:
- Using a NodePort or exposing the registry externally
- Using `localhost:PORT` if the registry is exposed on a NodePort

### Option 2: Configure containerd on K3s nodes

For Rancher Desktop/K3s on Lima VM, you need to configure containerd to:
1. Allow insecure registries for `gitea:3000`
2. Add a mirror/endpoint configuration

This typically involves:
```bash
# SSH into the Lima VM
limactl shell rancher-desktop

# Create/edit registries.yaml
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/registries.yaml > /dev/null <<EOF
mirrors:
  "gitea:3000":
    endpoint:
      - "http://gitea.applications.svc.cluster.local:3000"
configs:
  "gitea:3000":
    tls:
      insecure_skip_verify: true
EOF

# Restart k3s
sudo systemctl restart k3s
```

**Note**: The exact commands may vary depending on your Rancher Desktop setup.

### Option 3: Use Full Service DNS Name

Change all references to use `gitea.applications.svc.cluster.local:3000` everywhere. This is more verbose but may have better compatibility.

## Testing the Fix

1. **Verify the runner is configured**:
   ```bash
   kubectl logs -n applications -l app=act-runner -c dind --tail=20
   kubectl exec -n applications deployment/act-runner -c dind -- docker info | grep -A 5 "Insecure Registries"
   ```

2. **Verify connectivity from the runner**:
   ```bash
   kubectl exec -n applications deployment/act-runner -c dind -- wget -O- http://gitea:3000/api/healthz
   ```

3. **Push a test to trigger the workflow**:
   ```bash
   cd sample-django-app
   git add .
   git commit -m "Test workflow with gitea:3000 registry"
   git push
   ```

4. **Monitor the workflow**:
   - Check Gitea Actions UI at `http://localhost/gitea/remotelab/django-app/actions`
   - Watch runner logs: `kubectl logs -n applications -l app=act-runner -c runner -f`
   - Watch DinD logs: `kubectl logs -n applications -l app=act-runner -c dind -f`

## Troubleshooting

### Workflow still can't resolve gitea:3000
- Check that the runner pod restarted after applying the changes
- Verify DNS resolution from the DinD container: `kubectl exec -n applications deployment/act-runner -c dind -- nslookup gitea`

### K8s can't pull images
- You need to configure containerd on the nodes (see "K3s Node Configuration" above)
- Or use a different approach like NodePort exposure

### Authentication failures
- Ensure the `GITEA_TOKEN` secret is set correctly in the workflow
- Check Gitea user has proper permissions to push to the registry

## Alternative Approaches

If the above doesn't work in your environment, consider:

1. **Use localhost with NodePort**: Expose Gitea on a NodePort and use `localhost:PORT`
2. **Use host networking**: Run the act-runner with `hostNetwork: true`
3. **External registry**: Use an external registry service like Docker Hub or GitHub Container Registry
4. **Add to /etc/hosts**: Add `gitea` to /etc/hosts on the K3s node (not recommended, brittle)

## References

- [K3s Private Registry Configuration](https://docs.k3s.io/installation/private-registry)
- [Gitea Container Registry](https://docs.gitea.com/usage/packages/container)
- [Docker Insecure Registries](https://docs.docker.com/registry/insecure/)
