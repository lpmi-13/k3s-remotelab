# Django Remotelab API

A sample Django REST API application designed for K3s remotelab CI/CD pipeline demonstration. This application showcases automated building, testing, and deployment using Gitea Actions and ArgoCD.

## Features

- **Django REST Framework**: Modern API development
- **Redis Integration**: Caching and session storage
- **Prometheus Metrics**: Application monitoring
- **Health Checks**: Kubernetes-ready endpoints
- **Path-based Routing**: Works with reverse proxies
- **Container-ready**: Optimized Docker configuration
- **CI/CD Pipeline**: Automated build and deployment

## API Endpoints

- **Health Check**: `GET /api/health/` - Service health status
- **System Info**: `GET /api/system/` - System information with Redis caching
- **API Info**: `GET /api/info/` - API documentation and endpoints
- **Metrics**: `GET /metrics` - Prometheus metrics
- **Admin**: `GET /admin/` - Django admin interface

## Quick Start

### Local Development

1. **Clone the repository**:
   ```bash
   git clone https://gitea.remotelab.local/remotelab/django-app.git
   cd django-app
   ```

2. **Set up virtual environment**:
   ```bash
   python -m venv venv
   source venv/bin/activate  # On Windows: venv\Scripts\activate
   ```

3. **Install dependencies**:
   ```bash
   pip install -r requirements.txt
   ```

4. **Set up environment variables**:
   ```bash
   export DEBUG=true
   export SECRET_KEY=your-secret-key-here
   export REDIS_URL=redis://localhost:6379/1
   ```

5. **Run migrations**:
   ```bash
   python manage.py migrate
   ```

6. **Start development server**:
   ```bash
   python manage.py runserver
   ```

7. **Access the application**:
   - API: http://localhost:8000/api/
   - Health: http://localhost:8000/api/health/
   - Admin: http://localhost:8000/admin/

### Docker Development

1. **Build the container**:
   ```bash
   docker build -t django-app .
   ```

2. **Run with Docker Compose** (create docker-compose.yml):
   ```yaml
   version: '3.8'
   services:
     django:
       build: .
       ports:
         - "8000:8000"
       environment:
         - DEBUG=true
         - REDIS_URL=redis://redis:6379/1
       depends_on:
         - redis
     redis:
       image: redis:7-alpine
       ports:
         - "6379:6379"
   ```

3. **Start services**:
   ```bash
   docker-compose up
   ```

## CI/CD Pipeline

### Overview

The CI/CD pipeline automatically:

1. **Runs tests** on every push and pull request
2. **Builds Docker image** on main branch commits
3. **Pushes to Gitea registry** with multiple tags
4. **Scans for vulnerabilities** using Trivy
5. **Updates ArgoCD** to deploy new version

### Gitea Actions Workflow

The `.gitea/workflows/build.yml` file defines three jobs:

#### 1. Test Job
- Sets up Python 3.11
- Installs dependencies
- Runs Django tests
- Checks code style with flake8

#### 2. Build and Push Job
- Builds multi-architecture Docker image (AMD64/ARM64)
- Pushes to Gitea container registry
- Tags with branch name, commit SHA, and 'latest'
- Uses build cache for faster builds

#### 3. Security Scan Job
- Scans Docker image for vulnerabilities
- Uploads results to security dashboard

### Required Secrets

Configure these secrets in your Gitea repository:

- `GITEA_TOKEN`: Personal access token for registry authentication

### Container Registry

Images are stored in Gitea's built-in container registry:

- **Registry URL**: `gitea.remotelab.local`
- **Image Path**: `gitea.remotelab.local/[username]/django-app`
- **Tags**: `latest`, `main-[sha]`, `[branch-name]`

## Kubernetes Deployment

### ArgoCD Integration

The application is deployed using ArgoCD with automatic image updates:

```yaml
metadata:
  annotations:
    argocd-image-updater.argoproj.io/image-list: django=gitea.remotelab.local/remotelab/django-app:latest
    argocd-image-updater.argoproj.io/write-back-method: git
    argocd-image-updater.argoproj.io/git-branch: main
```

### Deployment Features

- **Rolling Updates**: Zero-downtime deployments
- **Health Checks**: Readiness and liveness probes
- **Resource Limits**: CPU and memory constraints
- **Persistent Storage**: Database and media files
- **Service Discovery**: Internal cluster networking
- **Prometheus Monitoring**: Automatic metrics collection

### Environment Variables

The deployment uses these environment variables:

- `REDIS_URL`: Redis connection string
- `DEBUG`: Enable/disable debug mode
- `SECRET_KEY`: Django secret key

## Monitoring

### Prometheus Metrics

The application exposes metrics at `/metrics`:

- **Django metrics**: Request/response statistics
- **Database metrics**: Query performance
- **Cache metrics**: Redis operation statistics
- **Custom metrics**: Application-specific counters

### Health Checks

#### Readiness Probe
- **Endpoint**: `/api/health/`
- **Initial Delay**: 30 seconds
- **Period**: 10 seconds

#### Liveness Probe
- **Endpoint**: `/api/health/`
- **Initial Delay**: 60 seconds
- **Period**: 30 seconds

## Security

### Container Security

- **Non-root user**: Application runs as 'django' user
- **Minimal base image**: Python 3.11 slim
- **Security scanning**: Trivy vulnerability scanning
- **Multi-stage builds**: Reduced attack surface

### Application Security

- **Secret management**: Environment variables for sensitive data
- **CSRF protection**: Enabled for all forms
- **SQL injection protection**: Django ORM
- **XSS protection**: Template escaping

## Performance

### Optimization Features

- **Gunicorn WSGI server**: Production-ready with 3 workers
- **Redis caching**: Database query and session caching
- **Static file optimization**: Collected and served efficiently
- **Database optimization**: Proper indexing and queries

### Resource Usage

- **CPU**: 250m requests, 500m limits
- **Memory**: 256Mi requests, 512Mi limits
- **Storage**: 2Gi persistent volume

## Troubleshooting

### Common Issues

1. **Database Migration Errors**:
   ```bash
   kubectl exec -it deployment/django -- python manage.py migrate
   ```

2. **Redis Connection Issues**:
   - Check Redis service is running
   - Verify REDIS_URL environment variable
   - Check network policies

3. **Image Pull Errors**:
   - Verify registry credentials
   - Check image tag exists
   - Confirm registry accessibility

4. **Health Check Failures**:
   - Check application logs
   - Verify database connectivity
   - Confirm Redis availability

### Debugging Commands

```bash
# View application logs
kubectl logs deployment/django -f

# Execute commands in container
kubectl exec -it deployment/django -- bash

# Check service connectivity
kubectl exec -it deployment/django -- curl http://redis:6379

# View ArgoCD application status
kubectl get applications -n argocd
```

## Development Workflow

### Making Changes

1. **Create feature branch**:
   ```bash
   git checkout -b feature/new-endpoint
   ```

2. **Make changes and test locally**:
   ```bash
   python manage.py test
   python manage.py runserver
   ```

3. **Commit and push**:
   ```bash
   git add .
   git commit -m "Add new API endpoint"
   git push origin feature/new-endpoint
   ```

4. **Create pull request** in Gitea

5. **Merge to main** triggers automatic deployment

### Testing

```bash
# Run all tests
python manage.py test

# Run specific test
python manage.py test remotelab.api.tests.HealthCheckTestCase

# Run with coverage
pip install coverage
coverage run --source='.' manage.py test
coverage report
```

## Configuration

### Django Settings

Key configuration options in `remotelab/settings.py`:

- **FORCE_SCRIPT_NAME**: Path-based routing support
- **ALLOWED_HOSTS**: Permitted hostnames
- **DATABASES**: Database configuration
- **CACHES**: Redis cache settings
- **REST_FRAMEWORK**: API configuration

### Docker Configuration

The `Dockerfile` includes:

- **Multi-stage builds**: Optimized image size
- **Health checks**: Built-in container health monitoring
- **Non-root execution**: Security best practices
- **Build optimizations**: Layer caching and minimization

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass
6. Submit a pull request

## License

This is a sample application for educational purposes. Use as a starting point for your own projects.

## Support

For questions or issues:

1. Check the troubleshooting section
2. Review application logs
3. Consult the remotelab documentation
4. Create an issue in the repository