#!/bin/bash
set -e

# Configure K3s to trust gitea:3000 as an insecure registry
# This script works with Rancher Desktop on macOS/Linux

echo "=== K3s Registry Configuration for Gitea ==="
echo ""

# Detect if we're using Rancher Desktop
if command -v limactl >/dev/null 2>&1; then
    echo "Detected Rancher Desktop (Lima VM)"
    echo "Configuring registries.yaml in Lima VM..."
    echo ""

    # Create the registries.yaml content
    cat > /tmp/registries.yaml <<'EOF'
mirrors:
  "gitea:3000":
    endpoint:
      - "http://gitea.applications.svc.cluster.local:3000"
configs:
  "gitea:3000":
    tls:
      insecure_skip_verify: true
  "gitea.applications.svc.cluster.local:3000":
    tls:
      insecure_skip_verify: true
EOF

    echo "Registry configuration:"
    cat /tmp/registries.yaml
    echo ""

    # Copy to Lima VM and apply
    echo "Copying configuration to Lima VM..."
    limactl copy /tmp/registries.yaml rancher-desktop:/tmp/registries.yaml

    echo "Applying configuration in K3s..."
    limactl shell rancher-desktop sudo mkdir -p /etc/rancher/k3s
    limactl shell rancher-desktop sudo cp /tmp/registries.yaml /etc/rancher/k3s/registries.yaml

    echo ""
    echo "Restarting K3s to apply changes..."
    limactl shell rancher-desktop sudo systemctl restart k3s || \
        limactl shell rancher-desktop sudo rc-service k3s restart

    echo ""
    echo "Waiting for K3s to become ready..."
    sleep 10

    # Clean up
    rm /tmp/registries.yaml

    echo ""
    echo "Configuration complete!"
    echo ""
    echo "To verify, check that containerd can resolve the registry:"
    echo "  kubectl run test-registry --rm -it --image=busybox --restart=Never -- sh"
    echo ""

elif [ -d "/etc/rancher/k3s" ]; then
    echo "Detected native K3s installation"
    echo "Configuring registries.yaml..."
    echo ""

    # Create the registries.yaml content
    sudo tee /etc/rancher/k3s/registries.yaml > /dev/null <<'EOF'
mirrors:
  "gitea:3000":
    endpoint:
      - "http://gitea.applications.svc.cluster.local:3000"
configs:
  "gitea:3000":
    tls:
      insecure_skip_verify: true
  "gitea.applications.svc.cluster.local:3000":
    tls:
      insecure_skip_verify: true
EOF

    echo "Registry configuration applied:"
    sudo cat /etc/rancher/k3s/registries.yaml
    echo ""

    echo "Restarting K3s..."
    sudo systemctl restart k3s

    echo ""
    echo "Waiting for K3s to become ready..."
    sleep 10

    echo ""
    echo "Configuration complete!"

else
    echo "ERROR: Could not detect K3s setup type"
    echo ""
    echo "This script supports:"
    echo "  - Rancher Desktop with Lima"
    echo "  - Native K3s installations"
    echo ""
    echo "Please manually configure /etc/rancher/k3s/registries.yaml with:"
    echo ""
    cat <<'EOF'
mirrors:
  "gitea:3000":
    endpoint:
      - "http://gitea.applications.svc.cluster.local:3000"
configs:
  "gitea:3000":
    tls:
      insecure_skip_verify: true
  "gitea.applications.svc.cluster.local:3000":
    tls:
      insecure_skip_verify: true
EOF
    echo ""
    exit 1
fi

echo ""
echo "Next steps:"
echo "1. Verify the configuration:"
echo "   kubectl get nodes"
echo ""
echo "2. Test the registry from a pod:"
echo "   kubectl run test-registry --rm -it --image=busybox --restart=Never -- nslookup gitea.applications.svc.cluster.local"
echo ""
echo "3. Try pulling an image from the registry:"
echo "   kubectl run test-pull --rm -it --image=gitea:3000/remotelab/django-app:latest --restart=Never"
echo ""
