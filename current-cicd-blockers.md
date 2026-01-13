# Current CI/CD Pipeline Blockers

## Summary

The CI/CD pipeline successfully builds and pushes images to the Gitea registry, but fails at the final steps of image detection and deployment.

---

## Issue 1: Kubelet Cannot Resolve Internal Registry Hostname

**Symptom:**
```
Failed to pull image "gitea:3000/remotelab/django-app:1.0.2":
dial tcp: lookup gitea on 192.168.5.3:53: no such host
```

**Root Cause:**
- Kubelet/containerd runs on the host, not inside Kubernetes
- It uses the host's DNS server (192.168.5.3), not Kubernetes cluster DNS
- `gitea:3000` is only resolvable via Kubernetes DNS (CoreDNS)
- The k3s registry mirrors configuration (`/etc/rancher/k3s/registries.yaml`) was attempted but not honored

**Impact:**
- Pods cannot pull images from `gitea:3000/remotelab/django-app:*`
- Deployment stays on bootstrap image (`ghcr.io/lpmi-13/k3s-remotelab-django:latest`)

**Potential Fixes:**
1. Expose Gitea registry via NodePort on a host-accessible port
2. Add hostPort to Gitea deployment
3. Configure ingress to expose registry API on localhost
4. Fix k3s registry mirrors (requires investigation into why it's not working)

---

## Issue 2: ArgoCD Image Updater Cannot Resolve Registry Hostname

**Symptom:**
```
Could not get tags from registry: Get "https://gitea:3000/v2/":
dial tcp: lookup gitea on 10.43.0.10:53: no such host
```

**Root Cause:**
- Image Updater uses short hostname `gitea` instead of FQDN
- Kubernetes DNS requires FQDN for cross-namespace resolution: `gitea.applications.svc.cluster.local`
- The `registries.conf` in Image Updater uses `gitea:3000` which doesn't resolve

**Impact:**
- Image Updater cannot detect new images in the Gitea registry
- Automatic image updates don't trigger

**Fix:**
Update `manifests/gitops/argocd-image-updater.yaml` to use FQDN:
```yaml
registries:
- name: Gitea Registry
  prefix: gitea.applications.svc.cluster.local:3000
  api_url: http://gitea.applications.svc.cluster.local:3000
  ping: yes
  insecure: yes
  credentials: pullsecret:argocd/gitea-registry-creds
```

---

## Issue 3: Invalid Credentials Format in Image Updater

**Symptom:**
```
Could not set registry endpoint credentials:
invalid secret definition: argocd/gitea-registry-creds#username#password
```

**Root Cause:**
- The credentials format `secret:argocd/gitea-registry-creds#username#password` is incorrect
- Image Updater expects either:
  - `pullsecret:namespace/secret-name` for dockerconfigjson secrets
  - `secret:namespace/secret-name#key` for a single key containing credentials

**Impact:**
- Even if DNS resolved, Image Updater couldn't authenticate to the registry

**Fix:**
Change credentials format in `registries.conf`:
```yaml
# From:
credentials: secret:argocd/gitea-registry-creds#username#password

# To (for dockerconfigjson secret):
credentials: pullsecret:argocd/gitea-registry-creds

# Or create a secret with combined credentials and use:
credentials: secret:argocd/gitea-registry-creds#credentials
```

---

## What IS Working

| Component | Status |
|-----------|--------|
| Git push triggers Gitea Actions | ✅ Working |
| Workflow runs tests | ✅ Working |
| Docker image builds | ✅ Working |
| Image pushes to Gitea registry | ✅ Working (verified via API) |
| Trivy security scanning | ✅ Working |
| ArgoCD Application sync | ✅ Working |
| ArgoCD accessible at /argocd | ✅ Working |

---

## Recommended Fix Order

1. **Fix Image Updater credentials format** - Quick fix in `argocd-image-updater.yaml`
2. **Fix Image Updater DNS** - Use FQDN in `registries.conf`
3. **Fix kubelet registry access** - Add NodePort to Gitea service for registry API
4. **Update all image references** - Use the NodePort-accessible registry URL

---

## Files to Modify

| File | Changes Needed |
|------|----------------|
| `manifests/gitops/argocd-image-updater.yaml` | Fix credentials format, use FQDN for registry |
| `manifests/applications/gitea.yaml` | Add NodePort for registry (port 3000) |
| `manifests/applications/django/base/deployment.yaml` | Update image reference to use accessible registry |
| `argocd-apps/applications/django-app.yaml` | Update image-list annotation with accessible registry |
| `sample-django-app/.gitea/workflows/build.yml` | Update REGISTRY env var to accessible hostname |
