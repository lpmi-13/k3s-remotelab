# Gitea Container Registry Setup Guide

This guide walks you through setting up and using Gitea's built-in container registry for your remotelab.

## Prerequisites

- Gitea is deployed and running in the `applications` namespace
- Ingress is configured and working
- You have access to Gitea at `http://localhost/gitea`

## Step 1: Access Gitea and Create an Account

1. Open your browser and navigate to: `http://localhost/gitea`
2. Click "Register" to create a new account
3. Create an admin user (first user is automatically admin):
   - Username: `remotelab` (or your preferred username)
   - Email: Your email address
   - Password: Choose a secure password

## Step 2: Create a Repository for Your Container Images

1. Log in to Gitea
2. Click the "+" icon in the top right
3. Select "New Repository"
4. Fill in the details:
   - Repository name: `django-app`
   - Make it private or public as needed
5. Click "Create Repository"

## Step 3: Configure Docker to Use the Registry

The container registry is accessible at `localhost/v2` via the ingress.

### Option A: Use HTTP (Development/Testing)

Since we're using a local setup without proper TLS, configure Docker to allow insecure registry:

**Linux:**
```bash
# Edit Docker daemon configuration
sudo nano /etc/docker/daemon.json
```

Add or merge this configuration:
```json
{
  "insecure-registries": ["localhost"]
}
```

Restart Docker:
```bash
sudo systemctl restart docker
```

**Note:** For production, you should use proper TLS certificates.

#### macOS (Colima)

Colima uses containerd/k3s for the Kubernetes runtime. Configure registries via:

```bash
# SSH into Colima VM and configure registries
colima ssh -- sudo mkdir -p /etc/rancher/k3s
colima ssh -- sudo tee /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  localhost:
    endpoint:
      - "http://localhost"
configs:
  "localhost":
    tls:
      insecure_skip_verify: true
EOF

# Restart k3s to apply changes
colima ssh -- sudo systemctl restart k3s
```

Note: Colima uses containerd, which handles registry configuration differently than Docker daemon.

### Option B: Use with K3s (Recommended for this setup)

Since K3s uses containerd, we'll configure it to pull from localhost:

```bash
# Edit k3s registries configuration
sudo mkdir -p /etc/rancher/k3s
sudo nano /etc/rancher/k3s/registries.yaml
```

Add:
```yaml
mirrors:
  localhost:
    endpoint:
      - "http://localhost"
configs:
  "localhost":
    tls:
      insecure_skip_verify: true
```

Restart k3s:
```bash
sudo systemctl restart k3s
```

## Step 4: Log in to the Registry

```bash
docker login localhost
```

Enter your Gitea credentials:
- Username: Your Gitea username (e.g., `remotelab`)
- Password: Your Gitea password

## Step 5: Push Your Django Image

Now you can push your Django image to the registry:

```bash
# Tag the image for your Gitea registry
docker tag django-app:latest localhost/remotelab/django-app:latest

# Push to Gitea registry
docker push localhost/remotelab/django-app:latest
```

## Step 6: Update the Django Deployment

The Django deployment is already configured to pull from:
```
gitea:3000/remotelab/django-app:latest
```

However, since we're using `localhost` for the registry, we need to update it:

```bash
kubectl set image deployment/django -n applications \
  django=localhost/remotelab/django-app:latest
```

Or edit the manifest:
```yaml
# manifests/applications/django.yaml
image: localhost/remotelab/django-app:latest
```

## Step 7: Verify the Registry is Working

Check if your image is in Gitea:
1. Go to `http://localhost/gitea/remotelab/django-app`
2. Click on "Packages" tab
3. You should see your `django-app` container package

## Step 8: Import Image to K3s

Since K3s uses containerd, import the image:

```bash
# Pull from localhost registry
docker pull localhost/remotelab/django-app:latest

# Save and import to k3s
docker save localhost/remotelab/django-app:latest -o /tmp/django-app.tar
sudo k3s ctr images import /tmp/django-app.tar
rm /tmp/django-app.tar
```

Or use the helper script:
```bash
./scripts/import-image-to-k3s.sh
```

## Troubleshooting

### Issue: "dial tcp: lookup gitea:3000"

**Solution:** The deployment is trying to use `gitea:3000` but DNS isn't configured.

Add to `/etc/hosts`:
```
127.0.0.1 gitea:3000
```

Or update the deployment to use `localhost` instead.

### Issue: "x509: certificate signed by unknown authority"

**Solution:** You're hitting TLS verification issues. Use the insecure registry configuration above, or set up proper certificates.

### Issue: Container registry not enabled in Gitea

**Solution:** Check Gitea logs:
```bash
kubectl logs -n applications -l app=gitea
```

Verify the environment variables are set:
```bash
kubectl describe deployment/gitea -n applications | grep GITEA__packages
```

## Next Steps

1. **Set up CI/CD**: Configure Gitea Actions or ArgoCD Image Updater to automatically build and deploy on git push
2. **Enable TLS**: Add proper certificates using cert-manager for production
3. **Configure DNS**: Set up proper DNS resolution for `gitea:3000`
4. **Image Updater**: ArgoCD Image Updater is already configured to watch for new images

## Container Registry API Endpoints

- **Registry API v2:** `http://localhost/v2`
- **Gitea Web UI:** `http://localhost/gitea`
- **Health Check:** `http://localhost/v2/` (should return `{}`)

## References

- [Gitea Packages Documentation](https://docs.gitea.com/usage/packages/overview)
- [Docker Registry HTTP API V2](https://docs.docker.com/registry/spec/api/)
