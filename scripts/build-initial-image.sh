#!/bin/bash
set -e

echo "Building initial Django container image..."

# Check if sample Django app exists
if [ ! -d "sample-django-app" ]; then
    echo "Error: sample-django-app directory not found!"
    echo "Please run this script from the remotelab project root."
    exit 1
fi

# Build the initial Django image
echo "Building Django container image..."
cd sample-django-app
docker build -t django-app:latest .

# Tag for Gitea registry
docker tag django-app:latest gitea.homelab.local/homelab/django-app:latest

echo "Initial Django image built successfully!"
echo ""
echo "To push to Gitea registry once Gitea is running:"
echo "1. Create 'homelab' user and 'django-app' repository in Gitea"
echo "2. Enable container registry in Gitea"
echo "3. Login: docker login gitea.homelab.local"
echo "4. Push: docker push gitea.homelab.local/homelab/django-app:latest"
echo ""
echo "Or simply push code to the repository and let CI/CD build it automatically!"