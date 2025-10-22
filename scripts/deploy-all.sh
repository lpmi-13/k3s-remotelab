#!/bin/bash
set -e

echo "Deploying Homelab K3s Stack..."

# Build initial Django image if it doesn't exist
echo "Checking for initial Django container image..."
if ! docker images | grep -q "gitea.homelab.local/homelab/django-app"; then
    echo "Building initial Django container image..."
    ./scripts/build-initial-image.sh
fi

# Deploy namespaces first
echo "Creating namespaces..."
kubectl apply -f manifests/monitoring/namespace.yaml
kubectl apply -f manifests/applications/namespace.yaml
kubectl apply -f manifests/gitops/argocd-namespace.yaml

# Install ArgoCD Operator
echo "Installing ArgoCD Operator..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-operator/master/deploy/install.yaml

echo "Waiting for ArgoCD Operator to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-operator-controller-manager -n argocd

# Deploy ArgoCD instance
echo "Deploying ArgoCD instance..."
kubectl apply -f manifests/gitops/

echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Deploy monitoring stack
echo "Deploying monitoring stack..."
kubectl apply -f manifests/monitoring/

# Wait for Prometheus to be ready
echo "Waiting for Prometheus to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/prometheus -n monitoring

# Deploy applications
echo "Deploying applications..."
kubectl apply -f manifests/applications/

# Wait for applications to be ready
echo "Waiting for applications to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/postgresql -n applications
kubectl wait --for=condition=available --timeout=300s deployment/redis -n applications
kubectl wait --for=condition=available --timeout=300s deployment/gitea -n applications
kubectl wait --for=condition=available --timeout=300s deployment/django -n applications

# Deploy ingress
echo "Deploying ingress configurations..."
kubectl apply -f manifests/infrastructure/

echo "Deployment complete!"
echo ""
echo "Services are available at:"
echo "- ArgoCD: http://localhost/argocd"
echo "- Gitea: http://localhost/gitea"
echo "- Django API: http://localhost/django"
echo "- Prometheus: http://localhost/prometheus"
echo "- Grafana: http://localhost/grafana (admin/admin)"
echo ""
echo "ArgoCD credentials:"
echo "Username: admin"
echo "Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "Check ArgoCD logs if password retrieval fails")"
echo ""
echo "Note: All services use path-based routing, no /etc/hosts configuration required!"