# SOPS Age Keys

This directory contains age encryption keys for SOPS secret management.

## Key Files

- `local.key` - Age private key for local/development environment (gitignored)

## Initial Setup

Generate a new age key pair for the lab environment:

```bash
# Install age (if not already installed)
# macOS: brew install age
# Linux: apt install age

# Generate key pair
age-keygen -o secrets/keys/local.key

# The command will output the public key, e.g.:
# Public key: age1abc123...
```

## Configure SOPS

After generating the key, update `secrets/.sops.yaml` with your public key:

```yaml
creation_rules:
  - path_regex: .*-secrets\.yaml\.enc$
    age: >-
      age1your-public-key-here...
```

## Usage

### Editing Encrypted Secrets

```bash
# Set the age key environment variable
export SOPS_AGE_KEY_FILE=$(pwd)/secrets/keys/local.key

# Edit secrets (opens in $EDITOR, saves encrypted on exit)
sops sample-django-app/chart/django-app/values/local-secrets.yaml.enc

# Or decrypt to stdout
sops -d sample-django-app/chart/django-app/values/local-secrets.yaml.enc
```

### Creating New Encrypted Files

```bash
# Create a new encrypted file
sops sample-django-app/chart/django-app/values/local-secrets.yaml.enc
```

## ArgoCD Integration

ArgoCD uses the helm-secrets plugin to decrypt SOPS-encrypted values.
The age private key is mounted as a Kubernetes secret in the argocd namespace.

To update the ArgoCD secret after key rotation:

```bash
kubectl create secret generic sops-age-key \
  --namespace argocd \
  --from-file=key.txt=secrets/keys/local.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Security Notes

- **Never commit `*.key` files to git** - they are gitignored by default
- The public key in `.sops.yaml` is safe to commit
- Rotate keys periodically and update ArgoCD secret accordingly
- For production, consider using cloud KMS (AWS KMS, GCP KMS, Azure Key Vault)
