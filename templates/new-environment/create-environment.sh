#!/bin/bash
# Script to create a new environment for k3s-remotelab
# Usage: ./create-environment.sh <environment-name>

set -e

ENV_NAME="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VALUES_DIR="${REPO_ROOT}/sample-django-app/chart/django-app/values"

if [ -z "$ENV_NAME" ]; then
    echo "Usage: $0 <environment-name>"
    echo "Example: $0 staging"
    exit 1
fi

echo "Creating environment: ${ENV_NAME}"

# Check if SOPS is installed
if ! command -v sops &> /dev/null; then
    echo "Error: sops is not installed"
    echo "Install with: brew install sops (macOS) or apt install sops (Linux)"
    exit 1
fi

# Check if age is installed
if ! command -v age-keygen &> /dev/null; then
    echo "Error: age is not installed"
    echo "Install with: brew install age (macOS) or apt install age (Linux)"
    exit 1
fi

# Create values file for the environment
VALUES_FILE="${VALUES_DIR}/${ENV_NAME}-values.yaml"
SECRETS_FILE="${VALUES_DIR}/${ENV_NAME}-secrets.yaml.enc"

if [ -f "$VALUES_FILE" ]; then
    echo "Warning: ${VALUES_FILE} already exists, skipping"
else
    cat > "$VALUES_FILE" << EOF
# Environment-specific values for ${ENV_NAME}
# Non-sensitive configuration only

# Override image settings if needed
# image:
#   tag: specific-version

# Environment-specific settings
env:
  DEBUG: "false"
  # Add environment-specific non-sensitive config here

# Resource overrides (optional)
# resources:
#   limits:
#     cpu: 1000m
#     memory: 1Gi
EOF
    echo "Created: ${VALUES_FILE}"
fi

# Check for age key
AGE_KEY_FILE="${REPO_ROOT}/secrets/keys/${ENV_NAME}.key"
if [ ! -f "$AGE_KEY_FILE" ]; then
    echo ""
    echo "Generating age key for ${ENV_NAME} environment..."
    age-keygen -o "$AGE_KEY_FILE" 2>&1 | tee /tmp/age-key-output.txt
    PUBLIC_KEY=$(grep "public key:" /tmp/age-key-output.txt | awk '{print $3}')
    rm /tmp/age-key-output.txt

    echo ""
    echo "Age key generated: ${AGE_KEY_FILE}"
    echo "Public key: ${PUBLIC_KEY}"
    echo ""
    echo "Add this public key to secrets/.sops.yaml:"
    echo ""
    echo "  - path_regex: .*${ENV_NAME}-secrets\\.yaml\\.enc\$"
    echo "    age: >-"
    echo "      ${PUBLIC_KEY}"
else
    echo "Age key already exists: ${AGE_KEY_FILE}"
fi

# Create encrypted secrets file
if [ -f "$SECRETS_FILE" ]; then
    echo "Warning: ${SECRETS_FILE} already exists, skipping"
else
    export SOPS_AGE_KEY_FILE="${REPO_ROOT}/secrets/keys/local.key"
    if [ ! -f "$SOPS_AGE_KEY_FILE" ]; then
        export SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}"
    fi

    # Create a temporary unencrypted file
    TEMP_SECRETS="/tmp/${ENV_NAME}-secrets.yaml"
    cat > "$TEMP_SECRETS" << EOF
# Encrypted secrets for ${ENV_NAME} environment
# Edit with: SOPS_AGE_KEY_FILE=secrets/keys/${ENV_NAME}.key sops ${SECRETS_FILE}

secrets:
  # Django secret key - generate a new one for each environment
  secretKey: "django-secret-key-change-me-$(openssl rand -hex 16)"

  # Database credentials
  database:
    password: "db-password-change-me"

  # External integration credentials (if needed)
  # erp:
  #   apiKey: "erp-api-key"
  # shipping:
  #   apiKey: "shipping-api-key"
EOF

    # Encrypt with SOPS
    sops --encrypt "$TEMP_SECRETS" > "$SECRETS_FILE"
    rm "$TEMP_SECRETS"

    echo "Created encrypted secrets file: ${SECRETS_FILE}"
fi

echo ""
echo "Environment ${ENV_NAME} created successfully!"
echo ""
echo "Next steps:"
echo "1. Update secrets/.sops.yaml with the public key (if using a new key)"
echo "2. Edit secrets: SOPS_AGE_KEY_FILE=secrets/keys/${ENV_NAME}.key sops ${SECRETS_FILE}"
echo "3. Create ArgoCD Application manifest for the environment"
echo "4. Commit changes and push to trigger deployment"
