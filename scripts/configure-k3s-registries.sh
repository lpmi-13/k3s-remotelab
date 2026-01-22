#!/bin/bash
set -e

# Configure K3s to trust gitea:3000 as an insecure registry
# This script works with Colima on macOS or native K3s on Linux

echo "=== K3s Registry Configuration for Gitea ==="
echo ""

# Detect if we're using Colima
if command -v colima >/dev/null 2>&1 && colima status &>/dev/null; then
    echo "Detected Colima on macOS"
    echo "Configuring registries.yaml in Colima VM..."
    echo ""

    # Create the registries.yaml content
    # Uses localhost:30300 (NodePort) which is accessible from the k3s node
    cat > /tmp/registries.yaml <<'EOF'
mirrors:
  "localhost:30300":
    endpoint:
      - "http://localhost:30300"
  docker.io:
    endpoint:
      - "https://registry-1.docker.io"
EOF

    echo "Registry configuration:"
    cat /tmp/registries.yaml
    echo ""

    # Apply configuration directly in the VM
    echo "Applying configuration in K3s..."
    colima ssh -- sudo mkdir -p /etc/rancher/k3s
    colima ssh -- sudo tee /etc/rancher/k3s/registries.yaml < /tmp/registries.yaml > /dev/null

    echo ""
    echo "Restarting K3s to apply changes..."
    colima ssh -- sudo systemctl restart k3s 2>/dev/null || \
        colima ssh -- "sudo pkill -HUP k3s" 2>/dev/null || \
        echo "Note: K3s restart may require manual intervention"

    echo ""
    echo "Waiting for K3s to become ready..."
    sleep 15

    # Clean up
    rm /tmp/registries.yaml

    echo ""
    echo "Configuration complete!"
    echo ""

elif command -v limactl >/dev/null 2>&1; then
    echo "Detected Lima (generic)"
    echo "Configuring registries.yaml in Lima VM..."
    echo ""

    # Create the registries.yaml content
    # Uses localhost:30300 (NodePort) which is accessible from the k3s node
    cat > /tmp/registries.yaml <<'EOF'
mirrors:
  "localhost:30300":
    endpoint:
      - "http://localhost:30300"
  docker.io:
    endpoint:
      - "https://registry-1.docker.io"
EOF

    echo "Registry configuration:"
    cat /tmp/registries.yaml
    echo ""

    # Copy to Lima VM and apply
    echo "Copying configuration to Lima VM..."
    limactl copy /tmp/registries.yaml default:/tmp/registries.yaml

    echo "Applying configuration in K3s..."
    limactl shell default sudo mkdir -p /etc/rancher/k3s
    limactl shell default sudo cp /tmp/registries.yaml /etc/rancher/k3s/registries.yaml

    echo ""
    echo "Restarting K3s to apply changes..."
    limactl shell default sudo systemctl restart k3s || \
        limactl shell default sudo rc-service k3s restart

    echo ""
    echo "Waiting for K3s to become ready..."
    sleep 10

    # Clean up
    rm /tmp/registries.yaml

    echo ""
    echo "Configuration complete!"
    echo ""

elif [ -d "/etc/rancher/k3s" ]; then
    echo "Detected native K3s installation"
    echo "Configuring registries.yaml..."
    echo ""

    # Create the registries.yaml content
    # Uses localhost:30300 (NodePort) which is accessible from the k3s node
    sudo tee /etc/rancher/k3s/registries.yaml > /dev/null <<'EOF'
mirrors:
  "localhost:30300":
    endpoint:
      - "http://localhost:30300"
  docker.io:
    endpoint:
      - "https://registry-1.docker.io"
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
    echo "  - Colima on macOS"
    echo "  - Lima (generic)"
    echo "  - Native K3s installations on Linux"
    echo ""
    echo "Please manually configure /etc/rancher/k3s/registries.yaml with:"
    echo ""
    cat <<'EOF'
mirrors:
  "localhost:30300":
    endpoint:
      - "http://localhost:30300"
  docker.io:
    endpoint:
      - "https://registry-1.docker.io"
EOF
    echo ""
    exit 1
fi

echo ""
echo "Next steps:"
echo "1. Verify the configuration:"
echo "   kubectl get nodes"
echo ""
echo "2. Try pulling an image from the registry:"
echo "   kubectl run test-pull --rm -it --image=localhost:30300/remotelab/django-app:latest --restart=Never"
echo ""
