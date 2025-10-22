# CI/CD Pipeline Implementation for Django Application

This document describes the complete CI/CD pipeline implementation for the Django application in the K3s homelab environment.

## Overview

The CI/CD pipeline enables the following workflow:

1. **Developer pushes code** to Gitea repository
2. **Gitea Actions** automatically builds and tests the application
3. **Docker image** is built and pushed to Gitea's container registry
4. **ArgoCD Image Updater** detects the new image
5. **ArgoCD** automatically deploys the updated application to Kubernetes

## Components

### 1. Sample Django Application

**Location**: `/home/adam/projects/remotelab/sample-django-app/`

A complete Django REST API application with:
- Proper project structure following Django best practices
- REST API endpoints with health checks and system information
- Redis integration for caching
- Prometheus metrics collection
- Comprehensive test suite
- Production-ready Dockerfile
- Path-based routing support for reverse proxies

**Key Files**:
- `Dockerfile` - Multi-stage container build
- `requirements.txt` - Python dependencies
- `.gitea/workflows/build.yml` - CI/CD pipeline
- `homelab/` - Django project directory
- `homelab/api/` - REST API application

### 2. Gitea Actions Workflow

**Location**: `/home/adam/projects/remotelab/sample-django-app/.gitea/workflows/build.yml`

Automated CI/CD pipeline with three jobs:

#### Test Job
- Runs on every push and pull request
- Sets up Python 3.11 environment
- Installs dependencies
- Executes Django test suite
- Performs code quality checks with flake8

#### Build and Push Job
- Triggers only on main branch commits
- Builds multi-architecture Docker image (AMD64/ARM64)
- Tags image with multiple strategies:
  - `latest` for main branch
  - `[branch]-[sha]` for commit tracking
  - `[branch]` for branch tracking
- Pushes to Gitea container registry
- Uses Docker layer caching for performance

#### Security Scan Job
- Scans built image for vulnerabilities using Trivy
- Uploads results to security dashboard
- Provides security visibility

### 3. Updated Django Deployment

**Location**: `/home/adam/projects/remotelab/manifests/applications/django.yaml`

The deployment manifest has been updated to:
- Use custom container image: `gitea.homelab.local/homelab/django-app:latest`
- Include ArgoCD Image Updater annotations for automatic updates
- Maintain all existing functionality (health checks, Redis integration, monitoring)
- Use environment variables for configuration
- Support rolling updates with zero downtime

**Key Changes**:
```yaml
metadata:
  annotations:
    argocd-image-updater.argoproj.io/image-list: django=gitea.homelab.local/homelab/django-app:latest
    argocd-image-updater.argoproj.io/write-back-method: git
    argocd-image-updater.argoproj.io/git-branch: main
spec:
  template:
    spec:
      containers:
      - name: django
        image: gitea.homelab.local/homelab/django-app:latest
```

### 4. ArgoCD Image Updater

**Location**: `/home/adam/projects/remotelab/manifests/gitops/argocd-image-updater.yaml`

Deployment of ArgoCD Image Updater component that:
- Monitors Gitea container registry for new images
- Updates ArgoCD applications automatically
- Supports Git write-back for GitOps workflow
- Handles authentication with Gitea registry
- Provides logging and monitoring capabilities

**Features**:
- Registry configuration for Gitea
- Git configuration for automatic commits
- RBAC permissions for ArgoCD integration
- Resource limits and health checks
- Secret management for registry credentials

**ArgoCD Application**: `/home/adam/projects/remotelab/argocd-apps/infrastructure/image-updater-app.yaml`

### 5. Container Registry Integration

The pipeline uses Gitea's built-in container registry:

- **Registry URL**: `gitea.homelab.local`
- **Authentication**: Using Gitea tokens
- **Image Naming**: `gitea.homelab.local/[username]/django-app`
- **Tag Strategy**: `latest`, branch-based, and SHA-based tags

## Workflow Details

### Developer Workflow

1. **Local Development**:
   ```bash
   git clone https://gitea.homelab.local/homelab/django-app.git
   cd django-app
   python -m venv venv
   source venv/bin/activate
   pip install -r requirements.txt
   python manage.py migrate
   python manage.py runserver
   ```

2. **Make Changes**:
   - Develop new features
   - Add tests
   - Update documentation

3. **Test Locally**:
   ```bash
   python manage.py test
   docker build -t django-app:test .
   docker run -p 8000:8000 django-app:test
   ```

4. **Push to Repository**:
   ```bash
   git add .
   git commit -m "Add new feature"
   git push origin main
   ```

### Automated Pipeline

1. **Gitea Actions Trigger**:
   - Pipeline starts automatically on push to main
   - Parallel execution of test and build jobs

2. **Testing Phase**:
   - Code quality checks
   - Unit test execution
   - Dependency validation

3. **Build Phase**:
   - Multi-architecture Docker build
   - Image optimization and security
   - Registry push with multiple tags

4. **Security Phase**:
   - Vulnerability scanning
   - Security report generation
   - Compliance checking

5. **Deployment Phase**:
   - ArgoCD Image Updater detection
   - Application manifest update
   - Rolling deployment execution
   - Health check validation

### Monitoring and Observability

The pipeline includes comprehensive monitoring:

#### Build Metrics
- Build duration and success rate
- Test coverage and results
- Security scan findings
- Resource usage during builds

#### Deployment Metrics
- Deployment frequency and success rate
- Rollback frequency and causes
- Application health and performance
- Resource utilization

#### Application Metrics
- API response times and error rates
- Cache hit ratios and performance
- Database query performance
- User activity and patterns

## Configuration Requirements

### Gitea Configuration

1. **Container Registry**: Enable built-in container registry
2. **Actions**: Configure Actions runners
3. **Secrets**: Set up repository secrets:
   - `GITEA_TOKEN`: Personal access token for registry

### ArgoCD Configuration

1. **Image Updater**: Deploy ArgoCD Image Updater component
2. **Registry Credentials**: Configure Gitea registry access
3. **Git Credentials**: Set up Git access for write-back
4. **Application Sync**: Configure sync policies

### Kubernetes Configuration

1. **RBAC**: Ensure proper permissions for ArgoCD
2. **Network Policies**: Allow communication between components
3. **Storage**: Configure persistent volumes for data
4. **Monitoring**: Set up Prometheus scraping

## Security Considerations

### Image Security
- Regular vulnerability scanning with Trivy
- Multi-stage builds to minimize attack surface
- Non-root container execution
- Minimal base images (Python slim)

### Access Control
- Repository access controls in Gitea
- RBAC in Kubernetes for ArgoCD
- Secret management for credentials
- Network policies for service communication

### Supply Chain Security
- Dependency scanning in CI pipeline
- Image signing and verification
- Audit logging for all changes
- Compliance with security policies

## Troubleshooting

### Common Issues

1. **Build Failures**:
   - Check Gitea Actions logs
   - Verify Docker build context
   - Validate dependencies and syntax

2. **Registry Issues**:
   - Verify Gitea registry is enabled
   - Check authentication credentials
   - Confirm network connectivity

3. **Deployment Issues**:
   - Check ArgoCD application status
   - Verify image updater logs
   - Validate Kubernetes resources

4. **Application Issues**:
   - Check pod logs and events
   - Verify health check endpoints
   - Confirm service connectivity

### Debugging Commands

```bash
# Check Gitea Actions
curl -H "Authorization: token $GITEA_TOKEN" \
     https://gitea.homelab.local/api/v1/repos/homelab/django-app/actions/runs

# Check ArgoCD applications
kubectl get applications -n argocd
kubectl describe application django-api -n argocd

# Check image updater
kubectl logs deployment/argocd-image-updater -n argocd

# Check Django application
kubectl logs deployment/django -n applications
kubectl exec -it deployment/django -n applications -- python manage.py check
```

## Performance Optimization

### Build Performance
- Docker layer caching
- Parallel job execution
- Dependency caching
- Multi-stage builds

### Deployment Performance
- Rolling updates for zero downtime
- Resource limits and requests
- Health check optimization
- Image pull policies

### Application Performance
- Redis caching configuration
- Database query optimization
- Static file serving
- Connection pooling

## Future Enhancements

### Possible Improvements

1. **Advanced Deployment Strategies**:
   - Blue-green deployments
   - Canary releases
   - Feature flags

2. **Enhanced Security**:
   - Image signing with Cosign
   - Policy enforcement with OPA
   - Runtime security monitoring

3. **Improved Observability**:
   - Distributed tracing
   - Custom metrics and alerts
   - Performance profiling

4. **Development Experience**:
   - Preview environments
   - Automated testing environments
   - Integration with IDEs

## Conclusion

This CI/CD implementation provides a complete, production-ready pipeline for Django applications in a K3s homelab environment. It demonstrates modern DevOps practices including:

- Infrastructure as Code with GitOps
- Automated testing and security scanning
- Container-native deployment strategies
- Comprehensive monitoring and observability
- Security best practices throughout the pipeline

The implementation serves as a foundation that can be extended and customized for specific requirements while maintaining the core principles of automation, reliability, and security.