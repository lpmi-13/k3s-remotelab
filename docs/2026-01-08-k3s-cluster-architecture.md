# K3s Cluster Architecture Research

**Date**: 2026-01-08 14:06:19 +0000
**Researcher**: Claude Code
**Git Commit**: c3a4bd0db1a94c9be113f8881b9b101a50cd1636
**Branch**: main
**Repository**: k3s-remotelab

## Research Question

Document the complete k3s cluster architecture to understand all components, their relationships, networking flow, CI/CD pipeline, and monitoring stack for creating an architecture diagram.

## Summary

The k3s-remotelab is a GitOps-driven, single-node Kubernetes cluster designed to be multi-node ready. The architecture consists of 5 main layers:

1. **Service Mesh Layer**: Linkerd provides automatic mTLS for all pod-to-pod communication
2. **Ingress Layer**: Traefik handles external traffic routing with HTTPS and path-based routing
3. **GitOps Layer**: ArgoCD manages continuous deployment with ArgoCD Image Updater for automated image updates
4. **Application Layer**: Django (REST API), Gitea (Git server + container registry), PostgreSQL, Redis, and Gitea Actions runner
5. **Monitoring Layer**: Prometheus collects metrics from all services, Grafana visualizes them

All services use path-based routing through a single HTTPS endpoint at `https://localhost/[service]` with automatic mTLS encryption between pods via Linkerd.

## Detailed Findings

### Service Mesh Layer (Linkerd)

**Purpose**: Provides zero-trust networking with automatic mTLS encryption for all service-to-service communication.

**Deployment**: Installed via linkerd CLI during deployment (/Users/adam.leskis/repos/k3s-remotelab/scripts/deploy-all.sh:100-130)
- Gateway API CRDs installed first
- Linkerd CRDs installed via `linkerd install --crds`
- Control plane installed with 7-day certificate validity: `linkerd install --identity-issuance-lifetime=168h0m0s`
- Deployed to `linkerd` namespace

**Components**:
- `linkerd-destination`: Service discovery and routing
- `linkerd-proxy-injector`: Automatically injects Linkerd proxy sidecars into pods

**Injection Behavior**:
- Enabled by namespace annotation: `linkerd.io/inject: enabled` (/Users/adam.leskis/repos/k3s-remotelab/manifests/applications/namespace.yaml:7-8, /Users/adam.leskis/repos/k3s-remotelab/manifests/monitoring/namespace.yaml:7-8)
- Automatically injects sidecar proxy into all pods in `applications`, `monitoring`, and `argocd` namespaces
- Disabled for Jobs via annotation: `linkerd.io/inject: disabled` (used in gitea-init-user, gitea-init-repo, act-runner)
- Each meshed pod shows 2/2 containers (app + linkerd-proxy)

**Features Provided**:
- Automatic mTLS for all TCP connections between pods
- Traffic metrics (request rates, latencies, success rates)
- Client-side load balancing with automatic retries
- Circuit breaking and failure detection

### Ingress Layer (Traefik + HTTPS)

**Ingress Controller**: Traefik (included with k3s by default)

**TLS Configuration**:
- All services use HTTPS with self-signed certificates
- Certificate secrets: `remotelab-tls` (applications), `monitoring-tls` (monitoring)
- HTTP automatically redirects to HTTPS via global middleware (/Users/adam.leskis/repos/k3s-remotelab/manifests/infrastructure/https-redirect.yaml:1-33)

**Path-Based Routing**:

All services accessible via `https://localhost/[path]`:

1. **Applications** (/Users/adam.leskis/repos/k3s-remotelab/manifests/infrastructure/ingress.yaml:26-58):
   - `/gitea` → gitea:3000 (Git UI and API)
   - `/v2` → gitea:3000 (Container registry API)
   - `/django` → django:8000 (REST API)

2. **Monitoring** (/Users/adam.leskis/repos/k3s-remotelab/manifests/infrastructure/ingress.yaml:59-91):
   - `/prometheus` → prometheus:9090
   - `/grafana` → grafana:3000

3. **GitOps** (/Users/adam.leskis/repos/k3s-remotelab/manifests/gitops/argocd-ingress.yaml:1-34):
   - `/argocd` → argocd-server:80

**Middlewares**: Strip path prefixes so backend services receive clean paths (/Users/adam.leskis/repos/k3s-remotelab/manifests/infrastructure/ingress.yaml:92-130):
- `strip-gitea`: Removes `/gitea` prefix
- `strip-django`: Removes `/django` prefix
- `strip-prometheus`: Removes `/prometheus` prefix
- `strip-grafana`: Removes `/grafana` prefix
- `strip-argocd`: Removes `/argocd` prefix

### GitOps Layer (ArgoCD)

**ArgoCD Core** (/Users/adam.leskis/repos/k3s-remotelab/scripts/deploy-all.sh:143-156):
- Deployed to `argocd` namespace
- Installed from official manifests: `https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`
- Configured for path-based routing via ConfigMap (/Users/adam.leskis/repos/k3s-remotelab/manifests/gitops/argocd-cmd-params-cm.yaml:10-14):
  - `server.insecure: "true"` (TLS handled by Traefik)
  - `server.rootpath: "/argocd"`
  - `server.basehref: "/argocd"`

**ArgoCD Image Updater** (/Users/adam.leskis/repos/k3s-remotelab/manifests/gitops/argocd-image-updater.yaml:1-181):
- Monitors Gitea container registry for new images
- Automatically updates application manifests when new images are pushed
- Uses Git write-back to update manifests in the repository
- Registry configuration for Gitea at `gitea:3000`
- Credentials stored in secret `gitea-registry-creds`

**Image Update Strategy**: The Django deployment uses annotations for automatic updates (/Users/adam.leskis/repos/k3s-remotelab/manifests/applications/django.yaml:9-12):
```yaml
argocd-image-updater.argoproj.io/image-list: django=gitea:3000/remotelab/django-app:1.x
argocd-image-updater.argoproj.io/django.update-strategy: semver
argocd-image-updater.argoproj.io/write-back-method: git
argocd-image-updater.argoproj.io/git-branch: main
```

### Application Layer

#### 1. Django Application

**Deployment** (/Users/adam.leskis/repos/k3s-remotelab/manifests/applications/django.yaml:1-93):
- Namespace: `applications`
- Initial image: `ghcr.io/lpmi-13/k3s-remotelab-django:latest`
- Target image (after CI/CD): `gitea:3000/remotelab/django-app:1.x`
- Port: 8000
- Replicas: 1

**Configuration**:
- Environment variables:
  - `REDIS_URL: "redis://redis:6379/1"` (connects to Redis service)
  - `DEBUG: "false"`
  - `SECRET_KEY`: Static key (should be changed in production)
- Health checks: `/api/health/` endpoint
- Prometheus metrics: Exposed at `/metrics` on port 8000

**Storage**: PersistentVolumeClaim `django-pvc` (2Gi, local-path) mounted at `/app/data`

**Service**: ClusterIP on port 8000

#### 2. Gitea (Git Server + Container Registry)

**Deployment** (/Users/adam.leskis/repos/k3s-remotelab/manifests/applications/gitea.yaml:1-129):
- Namespace: `applications`
- Image: `gitea/gitea:1.22`
- Ports: 3000 (HTTP), 22 (SSH)
- Replicas: 1

**Configuration**:
- Database: PostgreSQL backend
  - Host: `postgresql:5432`
  - Database: `gitea`
  - User: `gitea`
  - Password: From secret `postgresql-secret`
- Server settings:
  - Domain: `localhost`
  - Root URL: `https://localhost/gitea/`
- Features enabled:
  - Metrics: `/metrics` endpoint with token "prometheus"
  - Packages: Container registry at `/v2`
  - Actions: Gitea Actions CI/CD enabled
  - Default repo units: code, releases, issues, pulls, actions

**Storage**: PersistentVolumeClaim `gitea-pvc` (10Gi, local-path) mounted at `/data`

**Services**:
- ClusterIP on port 3000 (HTTP)
- ClusterIP on port 22 (SSH)

**Initialization** (/Users/adam.leskis/repos/k3s-remotelab/scripts/deploy-all.sh:192-280):
1. Admin user created via Job `gitea-init-user` (username: `remotelab`, password: `remotelab`)
2. Django repository initialized via Job `gitea-init-repo`:
   - Clones source code from GitHub: `https://github.com/lpmi-13/k3s-remotelab.git`
   - Extracts `sample-django-app/` directory
   - Creates new repository `django-app` in Gitea
   - Pushes code with `.gitea/workflows/` for CI/CD
   - Creates API token for workflow authentication

#### 3. PostgreSQL

**Deployment** (/Users/adam.leskis/repos/k3s-remotelab/manifests/applications/postgresql.yaml:1-85):
- Namespace: `applications`
- Image: `postgres:15`
- Port: 5432
- Replicas: 1

**Configuration**:
- Database: `gitea`
- User: `gitea`
- Password: `gitea_password` (base64 encoded in secret)
- Data directory: `/var/lib/postgresql/data/pgdata`

**Storage**: PersistentVolumeClaim `postgresql-pvc` (5Gi, local-path)

**Service**: ClusterIP on port 5432

**Purpose**: Backend database for Gitea

#### 4. Redis

**Deployment** (/Users/adam.leskis/repos/k3s-remotelab/manifests/applications/redis.yaml:1-82):
- Namespace: `applications`
- Image: `redis:7-alpine`
- Port: 6379
- Replicas: 1

**Configuration**:
- Persistence: AOF (append-only file) enabled
- Command: `redis-server --appendonly yes`
- Health checks: `redis-cli ping`

**Storage**: PersistentVolumeClaim `redis-pvc` (1Gi, local-path) mounted at `/data`

**Service**: ClusterIP on port 6379

**Purpose**: Caching backend for Django application

#### 5. Gitea Actions Runner

**Deployment** (/Users/adam.leskis/repos/k3s-remotelab/manifests/applications/gitea-actions-runner.yaml:25-81):
- Namespace: `applications`
- Image: `gitea/act_runner:nightly-dind-rootless`
- Replicas: 1
- Linkerd injection: **DISABLED** (annotation: `linkerd.io/inject: disabled`)

**Configuration**:
- Gitea instance: `http://gitea:3000` (uses internal service, not HTTPS ingress)
- Runner name: `k3s-runner`
- Registration token: Dynamic token generated during deployment and stored in secret `runner-secret`
- Docker-in-Docker: Uses TLS with certs at `/certs/client`
- Security context: Privileged mode enabled for container builds

**Storage**: PersistentVolumeClaim `act-runner-pvc` (5Gi, local-path) mounted at `/data`

**Token Management** (/Users/adam.leskis/repos/k3s-remotelab/scripts/deploy-all.sh:208-246):
1. Token generated via Gitea CLI: `gitea actions generate-runner-token`
2. Static placeholder in manifest is overwritten via kubectl patch
3. Runner pod restarted to pick up new token

### Monitoring Layer

#### Prometheus

**Deployment** (/Users/adam.leskis/repos/k3s-remotelab/manifests/monitoring/prometheus-deployment.yaml:1-79):
- Namespace: `monitoring`
- Image: `prom/prometheus:v2.45.0`
- Port: 9090
- Replicas: 1

**Configuration** (/Users/adam.leskis/repos/k3s-remotelab/manifests/monitoring/prometheus-config.yaml:1-83):
- Scrape interval: 15s
- External URL: `https://localhost/prometheus`
- Retention: 200 hours

**Scrape Jobs**:
1. `prometheus`: Self-monitoring at localhost:9090
2. `kubernetes-apiservers`: K8s API server metrics
3. `kubernetes-nodes`: Node-level metrics
4. `kubernetes-pods`: Pods with annotation `prometheus.io/scrape: "true"`
5. `gitea`: Static target at `gitea.applications.svc.cluster.local:3000/metrics`
6. `django`: Static target at `django.applications.svc.cluster.local:8000/metrics`

**Storage**: PersistentVolumeClaim `prometheus-pvc` (10Gi, local-path)

**Service**: ClusterIP on port 9090

#### Grafana

**Deployment** (/Users/adam.leskis/repos/k3s-remotelab/manifests/monitoring/grafana-deployment.yaml:1-93):
- Namespace: `monitoring`
- Image: `grafana/grafana:10.0.0`
- Port: 3000
- Replicas: 1

**Configuration**:
- Admin password: `admin` (base64 encoded in secret `grafana-admin-secret`)
- Root URL: `https://localhost/grafana/`
- Serve from sub-path: Enabled

**Data Sources** (/Users/adam.leskis/repos/k3s-remotelab/manifests/monitoring/grafana-config.yaml:7-14):
- Prometheus at `http://prometheus:9090` (default data source)

**Dashboards** (/Users/adam.leskis/repos/k3s-remotelab/manifests/monitoring/grafana-config.yaml:22-83):
- Kubernetes Cluster dashboard with:
  - Node CPU usage panel
  - Node memory usage panel
- Auto-refresh: 5 seconds

**Storage**: PersistentVolumeClaim `grafana-pvc` (1Gi, local-path)

**Service**: ClusterIP on port 3000

## CI/CD Pipeline Flow

### Complete Pipeline Workflow

1. **Developer Action**: Push code to Gitea repository at `https://localhost/gitea/remotelab/django-app`

2. **Gitea Actions Trigger** (/Users/adam.leskis/repos/k3s-remotelab/CICD_IMPLEMENTATION.md:38-69):
   - Workflow file: `.gitea/workflows/build.yaml` in repository
   - Runs on `act-runner` pod in `applications` namespace
   - Three parallel jobs:
     - **Test Job**: Runs Django tests and code quality checks
     - **Pull and Push Job**:
       - Pulls image from `ghcr.io/lpmi-13/k3s-remotelab-django:latest`
       - Re-tags with multiple strategies (latest, version.build, branch-sha)
       - Pushes to Gitea registry at `gitea:3000/remotelab/django-app`
     - **Security Scan Job**: Scans image with Trivy for vulnerabilities

3. **Image Registry**: New image available at Gitea container registry
   - Registry endpoint: `https://localhost/v2`
   - Internal URL: `gitea:3000`
   - Image path: `gitea:3000/remotelab/django-app:1.0.1`

4. **ArgoCD Image Updater Detection**:
   - Polls Gitea registry every interval
   - Detects new image matching semver pattern `1.x`
   - Updates Django deployment manifest image tag
   - Commits change back to Git repository (write-back method)

5. **ArgoCD Sync**:
   - Detects manifest change in Git
   - Compares desired state (Git) vs actual state (cluster)
   - Applies changes to cluster via kubectl
   - Performs rolling update of Django deployment

6. **Kubernetes Rolling Update**:
   - Creates new Django pod with updated image
   - Waits for readiness probe at `/api/health/`
   - Linkerd proxy automatically injected
   - Terminates old pod after new pod is ready
   - Zero-downtime deployment

### Traffic Flow

#### External Traffic Flow (User → Application)

```
Internet/Browser (HTTPS)
    ↓
https://localhost/[service]
    ↓
Traefik Ingress Controller (kube-system namespace)
- TLS termination (self-signed cert)
- Path-based routing
- Middleware: Strip path prefix
    ↓
Service (ClusterIP)
    ↓ (HTTP - TLS terminated)
Application Pod
    ↓
Linkerd Proxy Sidecar (ingress)
    ↓ (mTLS within pod)
Application Container
```

#### Internal Service-to-Service Traffic (Pod → Pod)

```
Django Container
    ↓
Linkerd Proxy Sidecar (egress in django pod)
    ↓ (mTLS over the network)
Linkerd Proxy Sidecar (ingress in redis pod)
    ↓
Redis Container
```

All pod-to-pod communication:
- Encrypted with mTLS via Linkerd
- Service discovery via Kubernetes DNS (e.g., `redis.applications.svc.cluster.local`)
- Automatic load balancing by Linkerd proxy
- Circuit breaking and retries

#### Monitoring Traffic Flow

```
Application Pods
- Django: Exposes /metrics on port 8000
- Gitea: Exposes /metrics on port 3000
    ↓
Prometheus (scrapes via mTLS)
    ↓ (stores time-series data)
Grafana (queries Prometheus at http://prometheus:9090)
    ↓
User Browser (https://localhost/grafana)
```

### Network Architecture

**Namespaces**:
- `linkerd`: Service mesh control plane
- `kube-system`: Traefik ingress, HTTPS redirect
- `argocd`: ArgoCD and Image Updater
- `applications`: Django, Gitea, PostgreSQL, Redis, Actions runner
- `monitoring`: Prometheus, Grafana

**Storage Class**: `local-path` (provided by k3s, single-node storage)

**DNS**: Internal Kubernetes DNS (CoreDNS)
- Service discovery format: `<service>.<namespace>.svc.cluster.local`
- Short form within namespace: `<service>`

**Network Policies**: Not explicitly defined (default allow-all in k3s)

**mTLS Coverage**:
- ✅ All pods in `applications` namespace (except Jobs and act-runner)
- ✅ All pods in `monitoring` namespace
- ✅ All pods in `argocd` namespace
- ❌ Jobs disabled (gitea-init-user, gitea-init-repo)
- ❌ act-runner disabled (privileged mode incompatible with Linkerd)

## Code References

- Deployment script: `/Users/adam.leskis/repos/k3s-remotelab/scripts/deploy-all.sh`
- Django deployment: `/Users/adam.leskis/repos/k3s-remotelab/manifests/applications/django.yaml`
- Gitea deployment: `/Users/adam.leskis/repos/k3s-remotelab/manifests/applications/gitea.yaml`
- PostgreSQL deployment: `/Users/adam.leskis/repos/k3s-remotelab/manifests/applications/postgresql.yaml`
- Redis deployment: `/Users/adam.leskis/repos/k3s-remotelab/manifests/applications/redis.yaml`
- Actions runner: `/Users/adam.leskis/repos/k3s-remotelab/manifests/applications/gitea-actions-runner.yaml`
- Prometheus config: `/Users/adam.leskis/repos/k3s-remotelab/manifests/monitoring/prometheus-config.yaml`
- Grafana deployment: `/Users/adam.leskis/repos/k3s-remotelab/manifests/monitoring/grafana-deployment.yaml`
- Ingress rules: `/Users/adam.leskis/repos/k3s-remotelab/manifests/infrastructure/ingress.yaml`
- HTTPS redirect: `/Users/adam.leskis/repos/k3s-remotelab/manifests/infrastructure/https-redirect.yaml`
- ArgoCD ingress: `/Users/adam.leskis/repos/k3s-remotelab/manifests/gitops/argocd-ingress.yaml`
- ArgoCD Image Updater: `/Users/adam.leskis/repos/k3s-remotelab/manifests/gitops/argocd-image-updater.yaml`

## Architecture Diagram Components Summary

### Layer 1: External Access
- HTTPS endpoint: `https://localhost/*`
- HTTP auto-redirects to HTTPS
- Self-signed TLS certificates

### Layer 2: Ingress (Traefik)
- Path-based routing to 6 services
- TLS termination
- Path stripping middlewares

### Layer 3: Service Mesh (Linkerd)
- mTLS for all pod-to-pod traffic
- Sidecar injection in 3 namespaces
- 7-day certificate rotation

### Layer 4: GitOps (ArgoCD)
- Continuous deployment from Git
- Image update automation
- Git write-back

### Layer 5: Applications
- **Django**: REST API with Redis caching
- **Gitea**: Git server + container registry + Actions CI/CD
- **PostgreSQL**: Database for Gitea
- **Redis**: Cache for Django
- **Actions Runner**: Docker-in-Docker CI/CD executor

### Layer 6: Monitoring
- **Prometheus**: Metrics collection from all services
- **Grafana**: Dashboards and visualization

### Storage
- All services use PersistentVolumeClaims with `local-path` storage class
- Total storage: ~34Gi allocated across all services

### Deployment Flow (CI/CD)
```
Code Push to Gitea
    ↓
Gitea Actions (act-runner)
    ↓
Pull from ghcr.io → Push to Gitea Registry
    ↓
ArgoCD Image Updater detects new image
    ↓
ArgoCD syncs updated manifest
    ↓
Kubernetes rolling update
    ↓
New pods with mTLS via Linkerd
```

### Key Connections
- Django → Redis (caching)
- Gitea → PostgreSQL (data storage)
- Actions Runner → Gitea (CI/CD)
- ArgoCD Image Updater → Gitea Registry (image monitoring)
- ArgoCD → Kubernetes API (deployment)
- Prometheus → All services (metrics scraping)
- Grafana → Prometheus (metrics visualization)
- All pods → Linkerd (mTLS encryption)

## Security Features

### Encryption
- External: HTTPS with self-signed certificates
- Internal: mTLS via Linkerd for all service-to-service traffic
- Certificate lifetime: 7 days (Linkerd auto-rotation)

### Authentication
- Gitea: Username/password (remotelab/remotelab)
- Grafana: Username/password (admin/admin)
- ArgoCD: Admin secret auto-generated
- Container registry: Gitea credentials

### Network Security
- All namespaces have Linkerd injection enabled
- Zero-trust model: mTLS required for pod communication
- No network policies defined (k3s default allow-all)

### Secret Management
- Kubernetes secrets for passwords and tokens
- Dynamic token generation for Gitea Actions runner
- Secret injection via environment variables
