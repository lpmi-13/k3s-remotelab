---
date: 2026-01-20T16:04:21+0000
researcher: Claude Code
git_commit: 120db9b0acfacc7c6b1f22ef267bb95383321349
branch: main
repository: k3s-remotelab
topic: "Impact of Adding Nginx TLS-Terminating Sidecar to Gitea for Container Registry"
tags: [research, gitea, nginx, container-registry, tls, sidecar]
status: complete
last_updated: 2026-01-20
last_updated_by: Claude Code
---

# Research: Impact of Adding Nginx TLS-Terminating Sidecar to Gitea for Container Registry

**Date**: 2026-01-20T16:04:21+0000
**Researcher**: Claude Code
**Git Commit**: 120db9b0acfacc7c6b1f22ef267bb95383321349
**Branch**: main
**Repository**: k3s-remotelab

## Research Question

Can an Nginx TLS-terminating sidecar be added to the Gitea deployment to provide HTTPS access on port 3443 for the container registry, while keeping HTTP on port 3000 working for all other traffic, WITHOUT requiring changes to Gitea's ROOT_URL or other configuration that would affect existing functionality?

## Summary

**YES - The Nginx sidecar approach (Option 2) can be implemented safely WITHOUT changing ROOT_URL or affecting existing functionality.** The current configuration already demonstrates this pattern is viable: the act-runner pod has an `localhost-proxy` sidecar that terminates TLS on port 443 and proxies to the Gitea service on port 3000. This exact pattern can be replicated in the Gitea deployment itself.

**Key Finding**: Gitea's ROOT_URL and LOCAL_ROOT_URL control how Gitea generates URLs for web UI, API links, and static assets. A sidecar proxy that simply forwards traffic to localhost:3000 does not require changes to these settings because:
1. The proxy does not modify the Host header (or sets it appropriately)
2. Gitea continues to see HTTP requests on port 3000
3. The TLS termination is transparent to Gitea
4. Registry clients specify the full URL including port (e.g., `gitea.example.com:3443`)

## Detailed Findings

### Current Gitea Configuration

The Gitea deployment is configured with the following critical settings ([gitea.yaml:25-73](file:///Users/adam.leskis/repos/k3s-remotelab/manifests/applications/gitea.yaml#L25-L73)):

```yaml
- name: GITEA__server__DOMAIN
  value: "gitea.applications.svc.cluster.local"
- name: GITEA__server__ROOT_URL
  value: "http://gitea.applications.svc.cluster.local:3000/"
- name: GITEA__server__LOCAL_ROOT_URL
  value: "http://gitea:3000/"
- name: GITEA__packages__ENABLED
  value: "true"
- name: GITEA__packages__REGISTRY_HOST_FQDN
  value: "gitea.applications.svc.cluster.local:3000"
```

**Important**: The ROOT_URL is set to HTTP on port 3000. Previous attempts to change this have caused cascading bugs with static assets and in-cluster communication, as noted in the research context.

### Existing Sidecar Proxy Pattern

The act-runner deployment already implements the exact pattern being proposed ([gitea-actions-runner.yaml:102-134](file:///Users/adam.leskis/repos/k3s-remotelab/manifests/applications/gitea-actions-runner.yaml#L102-L134)):

```yaml
- name: localhost-proxy
  image: nginx:alpine
  command: ["/bin/sh", "-c"]
  args:
  - |
    apk add --no-cache openssl > /dev/null 2>&1
    mkdir -p /certs
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout /certs/tls.key -out /certs/tls.crt \
      -subj "/CN=localhost" 2>/dev/null
    cat > /etc/nginx/nginx.conf << 'NGINX'
    events { worker_connections 1024; }
    http {
      server {
        listen 443 ssl;
        ssl_certificate /certs/tls.crt;
        ssl_certificate_key /certs/tls.key;
        location / {
          proxy_pass http://gitea.applications.svc.cluster.local:3000;
          proxy_set_header Host localhost;
          proxy_set_header X-Forwarded-Proto https;
        }
      }
    }
    NGINX
    nginx -g 'daemon off;'
```

**Key observations**:
1. This sidecar listens on port 443 (HTTPS)
2. It proxies to the external Gitea service on port 3000 (HTTP)
3. It sets `Host: localhost` header
4. It adds `X-Forwarded-Proto: https` header
5. This pattern is working successfully for the act-runner's DinD container to access the registry

### Container Registry Configuration

The container registry is accessed through multiple paths ([gitea.yaml:53-58](file:///Users/adam.leskis/repos/k3s-remotelab/manifests/applications/gitea.yaml#L53-L58)):

```yaml
- name: GITEA__packages__ENABLED
  value: "true"
- name: GITEA__packages__CHUNKED_UPLOAD_PATH
  value: "/data/packages/tmp"
- name: GITEA__packages__REGISTRY_HOST_FQDN
  value: "gitea.applications.svc.cluster.local:3000"
```

The `REGISTRY_HOST_FQDN` setting controls what hostname Gitea tells container registry clients to use. However, Docker/containerd clients specify the full registry URL themselves, so this setting is primarily for Gitea's internal URL generation.

### Current Registry Access Patterns

The codebase shows two primary registry access patterns:

1. **From Gitea Actions workflows** ([build.yml:14-16](file:///Users/adam.leskis/repos/k3s-remotelab/sample-django-app/.gitea/workflows/build.yml#L14-L16)):
```yaml
env:
  REGISTRY: gitea:3000
  IMAGE_NAME: django-app
```

2. **From Kubernetes nodes** ([gitea-registry-secret.yaml:10-11](file:///Users/adam.leskis/repos/k3s-remotelab/manifests/applications/gitea-registry-secret.yaml#L10-L11)):
```yaml
.dockerconfigjson: |
  {"auths":{"localhost:30300":{"username":"remotelab","password":"remotelab","auth":"cmVtb3RlbGFiOnJlbW90ZWxhYg=="}}}
```

The registry is currently accessed via:
- `gitea:3000` from within the cluster (internal service name)
- `localhost:30300` from outside the cluster (NodePort)

### Ingress Configuration

The current ingress setup shows TLS is already handled at the ingress level ([ingress.yaml:1-24](file:///Users/adam.leskis/repos/k3s-remotelab/manifests/infrastructure/ingress.yaml#L1-L24)):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitea-registry-ingress
  namespace: applications
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - localhost
    secretName: remotelab-tls
  rules:
  - http:
      paths:
      - path: /v2
        pathType: Prefix
        backend:
          service:
            name: gitea
            port:
              number: 3000
```

The ingress already terminates TLS and forwards to Gitea on port 3000. The web UI ingress also uses the same pattern ([ingress.yaml:26-50](file:///Users/adam.leskis/repos/k3s-remotelab/manifests/infrastructure/ingress.yaml#L26-L50)).

### DinD Registry Configuration

The Docker-in-Docker container in the act-runner is configured to trust both registries ([gitea-actions-runner.yaml:135-144](file:///Users/adam.leskis/repos/k3s-remotelab/manifests/applications/gitea-actions-runner.yaml#L135-L144)):

```yaml
- name: dind
  image: docker:27-dind
  env:
  - name: DOCKER_TLS_CERTDIR
    value: ""
  command:
  - dockerd
  - --host=unix:///var/run/docker.sock
  - --insecure-registry=gitea:3000
  - --insecure-registry=localhost
```

This shows that multiple registry endpoints can coexist, and the DinD daemon is already configured to handle both HTTP (insecure) registries.

### Historical Context

The documentation reveals important historical context about registry configuration:

1. **DNS Resolution Issues** ([gitea-registry-dns-fix.md:1-10](file:///Users/adam.leskis/repos/k3s-remotelab/docs/gitea-registry-dns-fix.md#L1-L10)): Previous issues with fake hostnames like `gitea:3000` that didn't exist in actual DNS led to using proper service names like `gitea:3000` (which auto-resolves within the namespace).

2. **In-Cluster vs External Access** ([gitea-registry-dns-fix.md:34-42](file:///Users/adam.leskis/repos/k3s-remotelab/docs/gitea-registry-dns-fix.md#L34-L42)): The service name `gitea:3000` resolves to `gitea.applications.svc.cluster.local:3000` from within the `applications` namespace due to Kubernetes DNS search suffixes.

3. **NodePort for External Access** ([gitea.yaml:126-137](file:///Users/adam.leskis/repos/k3s-remotelab/manifests/applications/gitea.yaml#L126-L137)): The service uses a fixed ClusterIP (10.43.200.100) and NodePort (30300) for container registry access from kubelet.

## Answer to Specific Questions

### 1. Do we need to change Gitea's ROOT_URL if we add an Nginx sidecar on port 3443 proxying to localhost:3000?

**NO.** The ROOT_URL can remain unchanged because:

- The sidecar would proxy traffic to `localhost:3000` within the same pod
- Gitea would continue to receive HTTP requests on port 3000
- The TLS termination happens before the request reaches Gitea
- The proxy should set the Host header appropriately (either preserve it or set it to match ROOT_URL's domain)
- Container registry clients specify the full URL including port explicitly

The existing localhost-proxy in the act-runner demonstrates this works: it proxies HTTPS on port 443 to Gitea's HTTP port 3000 without requiring Gitea configuration changes.

### 2. Would the Nginx sidecar affect Gitea's web UI, static assets, or API endpoints?

**NO - if implemented correctly.** The sidecar should be configured to:

1. **Selective routing**: Only listen on a specific port (3443) dedicated to registry traffic
2. **Preserve headers**: Set appropriate `Host` and `X-Forwarded-*` headers
3. **Path-agnostic**: Proxy all paths to maintain compatibility with the registry API

The web UI, static assets, and API endpoints would continue to be accessed through:
- Port 3000 (HTTP) for in-cluster traffic
- The existing ingress (HTTPS via Traefik) for external traffic

Since the sidecar would use a different port (3443), it would not interfere with existing access patterns.

**Example configuration** (based on the existing localhost-proxy pattern):
```yaml
- name: registry-tls-proxy
  image: nginx:alpine
  ports:
  - containerPort: 3443
    name: registry-https
  command: ["/bin/sh", "-c"]
  args:
  - |
    # Generate self-signed cert or use provided cert
    mkdir -p /certs
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout /certs/tls.key -out /certs/tls.crt \
      -subj "/CN=gitea.applications.svc.cluster.local" 2>/dev/null

    cat > /etc/nginx/nginx.conf << 'NGINX'
    events { worker_connections 1024; }
    http {
      server {
        listen 3443 ssl;
        ssl_certificate /certs/tls.crt;
        ssl_certificate_key /certs/tls.key;

        # Proxy to Gitea on localhost:3000
        location / {
          proxy_pass http://localhost:3000;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto https;
        }
      }
    }
    NGINX
    nginx -g 'daemon off;'
```

### 3. Can container registry traffic use HTTPS on port 3443 while other traffic continues on HTTP port 3000?

**YES.** This is entirely feasible because:

1. **Port isolation**: Different ports can serve different purposes. Port 3443 for registry HTTPS, port 3000 for existing HTTP traffic.

2. **Client-specified URLs**: Container registry clients (docker, podman, containerd) specify the full registry URL including port:
   - `docker push gitea.applications.svc.cluster.local:3443/remotelab/django-app:latest`
   - `docker push gitea.applications.svc.cluster.local:3000/remotelab/django-app:latest`

3. **Service configuration**: The Kubernetes service would be updated to expose both ports:
```yaml
ports:
- name: http
  port: 3000
  targetPort: 3000
  nodePort: 30300
- name: registry-https
  port: 3443
  targetPort: 3443
  nodePort: 30443  # if external access needed
```

4. **Coexistence**: The workflow in `build.yml` uses `REGISTRY: gitea:3000`, which would continue to work. New workflows or external clients could use port 3443 for HTTPS.

5. **DinD configuration**: The DinD container would need to be updated to trust the new registry endpoint:
```yaml
command:
- dockerd
- --host=unix:///var/run/docker.sock
- --insecure-registry=gitea:3000
- --insecure-registry=gitea:3443  # if using self-signed cert
- --insecure-registry=localhost
```

### 4. Are there any Gitea-specific configurations needed for registry access through a reverse proxy?

**Minimal to none.** Based on the current configuration and documentation:

1. **REGISTRY_HOST_FQDN**: Currently set to `gitea.applications.svc.cluster.local:3000`. This tells Gitea what hostname to advertise to registry clients. You might optionally update this to include the HTTPS port:
   ```yaml
   - name: GITEA__packages__REGISTRY_HOST_FQDN
     value: "gitea.applications.svc.cluster.local:3443"
   ```
   However, this is **not required** because:
   - Registry clients specify their own URLs
   - The setting is primarily for Gitea's web UI to display registry URLs
   - Multiple endpoints can coexist

2. **No ROOT_URL change needed**: As established, ROOT_URL controls web UI and API URL generation, not registry access patterns.

3. **X-Forwarded-Proto**: The proxy should set this header (as shown in the localhost-proxy example) so Gitea knows the client used HTTPS, though this is mainly for logging/metrics.

4. **No special registry proxy settings**: Gitea's container registry is just another HTTP endpoint (`/v2/*`), so standard reverse proxy configuration works.

## Code References

- `manifests/applications/gitea.yaml:25-73` - Current Gitea configuration with ROOT_URL and registry settings
- `manifests/applications/gitea.yaml:126-137` - Service configuration with NodePort for registry access
- `manifests/applications/gitea-actions-runner.yaml:102-134` - Existing localhost-proxy sidecar pattern (HTTPS → HTTP)
- `manifests/applications/gitea-actions-runner.yaml:135-144` - DinD insecure registry configuration
- `manifests/infrastructure/ingress.yaml:1-24` - Current TLS-terminating ingress for registry (/v2)
- `manifests/infrastructure/ingress.yaml:26-50` - Current TLS-terminating ingress for web UI
- `sample-django-app/.gitea/workflows/build.yml:14-16` - Workflow using gitea:3000 registry
- `manifests/applications/gitea-registry-secret.yaml:10-11` - Docker config for localhost:30300 registry
- `docs/gitea-registry-dns-fix.md:1-141` - Historical context on registry DNS configuration
- `docs/CONTAINER_REGISTRY_SETUP.md:1-211` - Registry setup and configuration guide

## Architecture Documentation

### Current Registry Access Patterns

1. **In-cluster access via service name**: `gitea:3000` or `gitea.applications.svc.cluster.local:3000`
2. **External access via NodePort**: `localhost:30300` (maps to port 3000)
3. **Web access via ingress**: `https://localhost/v2` (Traefik terminates TLS, forwards to port 3000)

### Sidecar Pattern Already in Use

The act-runner deployment demonstrates the sidecar TLS termination pattern:
- **localhost-proxy container**: Listens on port 443 with self-signed TLS
- **Proxies to**: Gitea service at `http://gitea.applications.svc.cluster.local:3000`
- **Used by**: DinD container for registry access via `localhost:443`
- **Configuration**: Uses host network mode, so workflow containers can reach localhost:443

### Proposed Pattern for Gitea Deployment

The same pattern can be applied directly to the Gitea deployment:
- **registry-tls-proxy container**: Listen on port 3443 with TLS
- **Proxies to**: `http://localhost:3000` (within the same pod)
- **Service update**: Expose port 3443 alongside port 3000
- **Client updates**: Registry clients can use `gitea:3443` for HTTPS or continue using `gitea:3000` for HTTP

### Key Design Principles

1. **Port separation**: Different ports = different access methods
2. **Transparent proxying**: Gitea sees normal HTTP requests on port 3000
3. **Backward compatibility**: Existing HTTP access on port 3000 remains unchanged
4. **TLS termination**: Happens in the sidecar, invisible to Gitea application
5. **No ROOT_URL changes**: Because Gitea's perspective doesn't change

## Conclusion

**Option 2 (Nginx TLS-terminating sidecar) is viable and safe to implement WITHOUT changing ROOT_URL or affecting existing functionality.**

The evidence strongly supports this conclusion:
1. The exact pattern already exists and works in the act-runner deployment
2. Gitea's ROOT_URL controls web UI/API URL generation, not how it receives proxied traffic
3. Different ports can serve different purposes without interference
4. The TLS termination is transparent to the Gitea application
5. Container registry clients specify full URLs including ports explicitly

**Implementation Checklist**:
- [ ] Add nginx sidecar container to Gitea deployment (similar to act-runner's localhost-proxy)
- [ ] Configure sidecar to listen on port 3443 with TLS
- [ ] Proxy to localhost:3000 with appropriate headers
- [ ] Update Gitea service to expose port 3443
- [ ] Update DinD insecure-registry configuration to include `gitea:3443`
- [ ] Test registry push/pull via both ports (3000 HTTP, 3443 HTTPS)
- [ ] Optionally update REGISTRY_HOST_FQDN to advertise port 3443
- [ ] NO changes needed to ROOT_URL or LOCAL_ROOT_URL

**Risk Assessment**: Low risk. The pattern is proven, the ports are isolated, and existing functionality remains untouched.
