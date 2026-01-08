#!/bin/bash
set -e

echo "Regenerating Gitea Actions runner token..."

# Generate a new runner token using the gitea CLI
echo "Generating new token from Gitea..."
NEW_TOKEN=$(kubectl exec -n applications deployment/gitea -c gitea -- su -c "/usr/local/bin/gitea actions generate-runner-token" git 2>&1 | grep -v "level=" | tail -1)

if [ -z "$NEW_TOKEN" ]; then
    echo "Error: Failed to generate token"
    exit 1
fi

echo "Generated token: $NEW_TOKEN"

# Update the runner secret
echo "Updating runner-secret..."
kubectl patch secret -n applications runner-secret -p "{\"stringData\":{\"token\":\"$NEW_TOKEN\"}}"

echo "Secret updated successfully"

# Restart the runner pod to pick up the new token
echo "Restarting runner pod..."
kubectl delete pod -n applications -l app=act-runner

echo "Done! Waiting for new runner pod to start..."
sleep 5
kubectl get pods -n applications -l app=act-runner

echo ""
echo "Runner token regenerated and applied successfully!"
echo "Check the runner logs with: kubectl logs -n applications -l app=act-runner --tail=50"
