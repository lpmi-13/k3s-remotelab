#!/bin/bash
set -e

echo "Installing ArgoCD Operator..."

# Install ArgoCD Operator
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD Operator
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-operator/master/deploy/install.yaml

echo "Waiting for ArgoCD Operator to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-operator-controller-manager -n argocd

echo "Deploying ArgoCD instance..."
kubectl apply -f manifests/gitops/

echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

echo "ArgoCD installed successfully!"
echo ""
echo "ArgoCD is available at: http://localhost/argocd"
echo ""
echo "Default credentials:"
echo "Username: admin"
echo "Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"
echo ""
echo "Note: Using path-based routing, no /etc/hosts configuration required!"