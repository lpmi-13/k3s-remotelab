# K3s Homelab

A GitOps-driven, single-node K3s homelab setup that's designed to be multi-node ready. This project includes ArgoCD as the core GitOps engine, Gitea for Git hosting, a Django REST Framework application, and a complete monitoring stack with Prometheus and Grafana.

## Architecture

- **GitOps-first**: ArgoCD manages all deployments with declarative configuration
- **Single-node first, multi-node ready**: Uses standard Kubernetes resources that scale naturally
- **Simple networking**: Uses path-based routing with Traefik for seamless access
- **Local storage**: Uses local-path provisioner for single-node, easily switchable to distributed storage
- **Continuous deployment**: Complete ArgoCD setup with App-of-Apps pattern for automated deployments

## Services

- **ArgoCD**: GitOps deployment management
- **Gitea**: Self-hosted Git service with PostgreSQL backend
- **Django**: REST Framework application with Redis caching
- **Prometheus**: Metrics collection and monitoring
- **Grafana**: Metrics visualization and dashboards

## Quick Start

### Prerequisites

- K3s cluster running (single-node)
- kubectl configured
- Docker available (for building initial container image)

### Deploy the Complete Stack

```bash
# Make scripts executable
chmod +x scripts/*.sh

# Deploy all services including ArgoCD
./scripts/deploy-all.sh
```

This will:
1. Build an initial Django container image locally
2. Deploy the complete GitOps-enabled homelab stack
3. Set up CI/CD pipeline for automatic deployments

## Service Access

Once deployed, services are available at:

- **ArgoCD**: http://localhost/argocd (GitOps management interface)
  - Username: `admin`
  - Password: Retrieved automatically during deployment
- **Gitea**: http://localhost/gitea
- **Django API**: http://localhost/django
  - Health check: `/django/api/health/`
  - System info: `/django/api/system/`
- **Prometheus**: http://localhost/prometheus
- **Grafana**: http://localhost/grafana (admin/admin)

## Directory Structure

```
├── manifests/              # Kubernetes manifests
│   ├── infrastructure/     # Ingress and core services
│   ├── monitoring/         # Prometheus + Grafana
│   ├── gitops/            # ArgoCD configuration
│   └── applications/       # Gitea + Django + dependencies
├── argocd-apps/           # ArgoCD Application definitions
│   ├── infrastructure/    # Infrastructure apps
│   └── applications/      # Service apps
├── config/                # Environment-specific configurations
│   ├── values-single-node.yaml
│   └── values-multi-node.yaml
└── scripts/               # Deployment scripts
```

## Multi-Node Migration

To migrate to a multi-node setup:

1. **Install distributed storage** (Longhorn recommended):
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/master/deploy/longhorn.yaml
   ```

2. **Update storage class** in manifests:
   ```yaml
   storageClassName: "longhorn"  # instead of "local-path"
   ```

3. **Increase replica counts** for high availability:
   ```yaml
   replicas: 3  # instead of 1
   ```

4. **Add pod anti-affinity** rules for workload distribution

## Configuration

### Single-Node Configuration

Uses `config/values-single-node.yaml`:
- Single replicas for all services
- Local-path storage
- Conservative resource limits

### Multi-Node Configuration

Uses `config/values-multi-node.yaml`:
- Multiple replicas for HA
- Distributed storage (Longhorn/NFS)
- Higher resource limits
- Pod anti-affinity rules

## Monitoring

### Prometheus Targets

- Kubernetes API server
- Kubernetes nodes
- All pods with `prometheus.io/scrape: "true"` annotation
- Gitea metrics endpoint
- Django metrics endpoint

### Grafana Dashboards

- Kubernetes cluster overview
- Node resource utilization
- Pod metrics
- Application-specific dashboards

## Security Notes

- Default passwords are used (change in production!)
- Self-signed certificates for TLS
- No authentication on most services (add in production!)
- RBAC configurations included but minimal

## Development

### Django Application

The Django app includes:
- REST API with health checks
- Redis integration for caching
- Prometheus metrics export
- Basic system information endpoint

### Adding New Services

1. Create manifests in appropriate directory
2. Add ingress rules if needed
3. Create ArgoCD Application definition
4. Update monitoring configuration

## Troubleshooting

### Service Not Starting
```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

### Storage Issues
```bash
kubectl get pv,pvc -A
kubectl describe pvc <pvc-name> -n <namespace>
```

### Network Issues
```bash
kubectl get ingress -A
kubectl describe ingress <ingress-name> -n <namespace>
```

### ArgoCD Issues
```bash
kubectl get applications -n argocd
kubectl describe application <app-name> -n argocd
```

## Contributing

1. Follow the existing patterns for new services
2. Ensure multi-node compatibility
3. Add monitoring for new services
4. Update documentation

## License

MIT License - see LICENSE file for details