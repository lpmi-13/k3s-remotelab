#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "${SCRIPT_DIR}/lib/platform.sh"
source "${SCRIPT_DIR}/lib/versions.sh"

TRAEFIK_CRD_DEFINITIONS_URL="https://raw.githubusercontent.com/traefik/traefik/v3.5/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml"
ARGOCD_ADMIN_PASSWORD="remotelab"
# bcrypt hash for ARGOCD_ADMIN_PASSWORD. ArgoCD stores the admin password hash
# in argocd-secret rather than the generated initial-admin secret.
ARGOCD_ADMIN_PASSWORD_HASH='$2a$10$53xm8W5NWtQbIe2oMGQlheoTFSxh4El7pz1Mdf3NHiRGdund2oPya'
IMAGE_TAG="${IMAGE_TAG:-${DEFAULT_FIRST_PARTY_IMAGE_TAG}}"
SCENARIO_CONTROLLER_IMAGE="${SCENARIO_CONTROLLER_IMAGE_REPO}:${IMAGE_TAG}"

show_help() {
    echo "Usage: ./deploy-all.sh [OPTIONS]"
    echo ""
    echo "Deploy the GitOps failure lab: k3s + ArgoCD + Gitea + Django app + Scenario Controller"
    echo ""
    echo "Options:"
    echo "  --skip-cleanup    Skip cleanup of existing resources"
    echo "  --help, -h        Show this help message"
    echo ""
    exit 0
}

SKIP_CLEANUP=false
if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    show_help
elif [[ "$1" == "--skip-cleanup" ]]; then
    SKIP_CLEANUP=true
elif [[ -n "$1" ]]; then
    echo "Error: Unknown option '$1'"
    show_help
fi

run_privileged() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

get_k3s_node_internal_ip() {
    local node_name="$1"
    kubectl get node "$node_name" \
        -o jsonpath='{range .status.addresses[?(@.type=="InternalIP")]}{.address}{end}' 2>/dev/null || true
}

get_kubernetes_endpoint_ip() {
    local endpoint_ip
    endpoint_ip=$(kubectl get endpointslices.discovery.k8s.io -n default \
        -l kubernetes.io/service-name=kubernetes \
        -o jsonpath='{.items[0].endpoints[0].addresses[0]}' 2>/dev/null || true)

    if [ -z "$endpoint_ip" ]; then
        endpoint_ip=$(kubectl get endpoints kubernetes -n default \
            -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
    fi

    echo "$endpoint_ip"
}

update_k3s_ip_config() {
    local desired_ip="$1"
    local config_file="/etc/rancher/k3s/config.yaml"
    local temp_file
    local next_file
    local timestamp

    temp_file=$(mktemp)
    next_file=$(mktemp)
    timestamp=$(date +%Y%m%d%H%M%S)

    if run_privileged test -f "$config_file"; then
        run_privileged awk '!/^(node-ip|advertise-address):[[:space:]]/' "$config_file" > "$temp_file"
        run_privileged cp "$config_file" "${config_file}.bak.${timestamp}"
    else
        : > "$temp_file"
        run_privileged mkdir -p "$(dirname "$config_file")"
    fi

    cat "$temp_file" > "$next_file"
    if [ -s "$next_file" ]; then
        printf '\n' >> "$next_file"
    fi
    {
        printf 'node-ip: %s\n' "$desired_ip"
        printf 'advertise-address: %s\n' "$desired_ip"
    } >> "$next_file"

    run_privileged install -m 0644 "$next_file" "$config_file"
    rm -f "$temp_file" "$next_file"
}

wait_for_k3s_api() {
    local waited=0

    while ! kubectl cluster-info &>/dev/null; do
        if [ $waited -ge 180 ]; then
            echo "  ERROR: k3s API did not become ready after restart"
            exit 1
        fi
        sleep 3
        waited=$((waited + 3))
    done
}

wait_for_k3s_advertised_ip() {
    local node_name="$1"
    local desired_ip="$2"
    local waited=0
    local node_ip
    local endpoint_ip

    while [ $waited -lt 180 ]; do
        node_ip=$(get_k3s_node_internal_ip "$node_name")
        endpoint_ip=$(get_kubernetes_endpoint_ip)

        if [[ "$node_ip" == "$desired_ip" && "$endpoint_ip" == "$desired_ip" ]]; then
            return 0
        fi

        sleep 3
        waited=$((waited + 3))
    done

    echo "  ERROR: k3s still advertises node IP '${node_ip:-unknown}' and API endpoint '${endpoint_ip:-unknown}'"
    echo "         Expected both to be '${desired_ip}'"
    exit 1
}

refresh_linux_coredns() {
    if ! kubectl -n kube-system get deployment coredns &>/dev/null; then
        echo "  WARNING: CoreDNS deployment not found; skipping DNS refresh"
        return 0
    fi

    echo "  Refreshing CoreDNS resolver state..."
    kubectl -n kube-system rollout restart deployment/coredns >/dev/null
    if ! kubectl -n kube-system rollout status deployment/coredns --timeout=120s >/dev/null; then
        echo "  ERROR: CoreDNS did not become ready after restart"
        exit 1
    fi
    echo "  OK: CoreDNS ready"
}

wait_for_traefik_middleware_api() {
    local waited=0

    while [ $waited -lt 60 ]; do
        if kubectl get middlewares.traefik.io -A &>/dev/null; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    echo "  ERROR: Traefik Middleware API did not become discoverable"
    exit 1
}

set_argocd_admin_password() {
    local password_mtime

    password_mtime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    kubectl -n argocd patch secret argocd-secret --type=merge \
        --patch "{\"stringData\":{\"admin.password\":\"${ARGOCD_ADMIN_PASSWORD_HASH}\",\"admin.passwordMtime\":\"${password_mtime}\"}}" >/dev/null
    kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found=true >/dev/null
    kubectl -n argocd rollout restart deployment/argocd-server >/dev/null
    kubectl -n argocd rollout status deployment/argocd-server --timeout=300s >/dev/null
}

ensure_traefik_crds() {
    if kubectl get crd middlewares.traefik.io &>/dev/null; then
        wait_for_traefik_middleware_api
        echo "  OK: Traefik CRDs present"
        return 0
    fi

    echo "  Installing Traefik CRDs..."
    kubectl apply -f "$TRAEFIK_CRD_DEFINITIONS_URL"
    kubectl wait --for=condition=Established --timeout=120s crd/middlewares.traefik.io >/dev/null
    wait_for_traefik_middleware_api
    echo "  OK: Traefik CRDs present"
}

repair_linux_k3s_ip_if_needed() {
    local desired_ip
    local node_name
    local node_ip
    local endpoint_ip

    desired_ip=$(get_node_ip)
    if [[ -z "$desired_ip" || "$desired_ip" == "127."* ]]; then
        echo "  ERROR: Could not determine a non-loopback host IP for k3s"
        exit 1
    fi

    node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "$node_name" ]; then
        echo "  ERROR: Could not determine k3s node name"
        exit 1
    fi

    node_ip=$(get_k3s_node_internal_ip "$node_name")
    endpoint_ip=$(get_kubernetes_endpoint_ip)

    if [[ "$node_ip" == "$desired_ip" && "$endpoint_ip" == "$desired_ip" ]]; then
        echo "  OK: k3s advertises current host IP ($desired_ip)"
        return 0
    fi

    echo "  Detected k3s IP drift:"
    echo "    current host IP:       $desired_ip"
    echo "    k3s node InternalIP:   ${node_ip:-unknown}"
    echo "    Kubernetes API endpoint: ${endpoint_ip:-unknown}"
    echo "  Updating /etc/rancher/k3s/config.yaml and restarting k3s..."

    update_k3s_ip_config "$desired_ip"
    run_privileged systemctl restart k3s

    echo "  Waiting for k3s API after restart..."
    wait_for_k3s_api
    kubectl wait --for=condition=Ready --timeout=180s "node/$node_name" >/dev/null
    wait_for_k3s_advertised_ip "$node_name" "$desired_ip"
    echo "  OK: k3s now advertises $desired_ip"
}

echo "=== GitOps Failure Lab - Deployment ==="
echo ""

# --- Platform Setup ---
OS=$(uname -s)

if [[ "$OS" == "Darwin" ]]; then
    echo "Step 1: Setting up Colima with k3s..."

    if ! command -v colima &>/dev/null; then
        echo "  ERROR: Colima is not installed. Install with: brew install colima"
        exit 1
    fi

    # Check current Colima state and configuration
    COLIMA_ACTION="create"  # create | start | none
    COLIMA_JSON=$(colima list --json 2>/dev/null || echo "")

    if [[ -n "$COLIMA_JSON" ]] && echo "$COLIMA_JSON" | grep -q '"name"'; then
        COLIMA_RUNTIME=$(echo "$COLIMA_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('runtime',''))" 2>/dev/null)
        COLIMA_STATUS=$(echo "$COLIMA_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null)

        if [[ "$COLIMA_RUNTIME" == "containerd+k3s" ]]; then
            if [[ "$COLIMA_STATUS" == "Running" ]]; then
                COLIMA_ACTION="none"
                echo "  Colima already running with correct config (containerd+k3s)"
            else
                COLIMA_ACTION="start"
                echo "  Colima stopped but has correct config, starting..."
            fi
        else
            # Wrong configuration (docker, containerd without k3s, etc.)
            echo "  Colima has wrong configuration: runtime=$COLIMA_RUNTIME"
            echo "  Required: containerd+k3s (--kubernetes --runtime containerd)"
            echo "  Deleting and recreating with correct settings..."
            colima stop --force 2>/dev/null || true
            colima delete --force 2>/dev/null || true
            COLIMA_ACTION="create"
        fi
    fi

    case "$COLIMA_ACTION" in
        create)
            colima delete --force 2>/dev/null || true
            echo "  Starting Colima with Kubernetes + containerd..."
            colima start --kubernetes --runtime containerd --cpu 4 --memory 6 --disk 60
            sleep 15
            ;;
        start)
            colima start
            sleep 15
            ;;
        none)
            ;;
    esac
    echo "  OK: Colima running"

    # Switch kubectl context
    COLIMA_CONTEXT=$(kubectl config get-contexts -o name 2>/dev/null | grep -i "colima" | head -n 1)
    if [ -z "$COLIMA_CONTEXT" ]; then
        echo "  ERROR: No colima kubectl context found. Try: colima kubernetes reset"
        exit 1
    fi
    kubectl config use-context "$COLIMA_CONTEXT" > /dev/null
    echo "  OK: Using context $COLIMA_CONTEXT"
else
    echo "Step 1: Verifying k3s..."
    if ! kubectl cluster-info &>/dev/null; then
        echo "  ERROR: Cannot connect to Kubernetes cluster"
        exit 1
    fi
    echo "  OK: kubectl connected"
    repair_linux_k3s_ip_if_needed
    refresh_linux_coredns
fi

# Verify cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
    echo "  ERROR: Cluster not responding"
    exit 1
fi
echo ""

# --- Cleanup ---
if [ "$SKIP_CLEANUP" = false ]; then
    echo "Step 2: Cleaning up existing resources..."
    for ns in applications argocd; do
        if kubectl get namespace "$ns" &>/dev/null; then
            echo "  Removing namespace: $ns"
            # Remove ArgoCD finalizers from Applications and Jobs
            if [ "$ns" = "argocd" ]; then
                kubectl get applications.argoproj.io -n argocd -o name 2>/dev/null | \
                    xargs -I {} kubectl patch {} -n argocd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            fi
            # Remove ArgoCD hook finalizers from Jobs (prevents namespace stuck in Terminating)
            kubectl get jobs -n "$ns" -o name 2>/dev/null | \
                xargs -I {} kubectl patch {} -n "$ns" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            kubectl delete namespace "$ns" --ignore-not-found=true --wait=false 2>/dev/null || true
        fi
    done
    # Wait for deletion
    for ns in applications argocd; do
        waited=0
        while kubectl get namespace "$ns" &>/dev/null && [ $waited -lt 90 ]; do
            # Clear any remaining finalizers blocking deletion
            kubectl get jobs -n "$ns" -o name 2>/dev/null | \
                xargs -I {} kubectl patch {} -n "$ns" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            kubectl patch namespace "$ns" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
            sleep 3
            waited=$((waited + 3))
        done
    done
    echo "  OK: Cleanup complete"
else
    echo "Step 2: Skipping cleanup"
fi
echo ""

# --- Create Namespaces ---
echo "Step 3: Creating namespaces..."
kubectl apply -f "$REPO_DIR/manifests/applications/namespace.yaml"
kubectl apply -f "$REPO_DIR/manifests/gitops/argocd-namespace.yaml"
echo "  OK: Namespaces created"
echo ""

# --- Install ArgoCD ---
echo "Step 4: Installing ArgoCD..."
kubectl apply --server-side --force-conflicts -n argocd \
    -f "$REPO_DIR/manifests/gitops/argocd-install.yaml"
echo "  Waiting for ArgoCD server..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
echo "  OK: ArgoCD installed"
echo ""

# --- Configure ArgoCD ---
echo "Step 5: Configuring ArgoCD (ingress, subpath)..."

# Apply ArgoCD customizations (non-SOPS parts first)
kubectl apply -f "$REPO_DIR/manifests/gitops/argocd-cmd-params-cm.yaml"
kubectl apply -f "$REPO_DIR/manifests/gitops/argocd-ingress.yaml"

# Patch ArgoCD server for subpath
kubectl patch deployment argocd-server -n argocd --type='strategic' \
    --patch-file "$REPO_DIR/manifests/gitops/argocd-server-patch.yaml"

kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Set a deterministic admin password.
echo "  Setting ArgoCD admin password..."
set_argocd_admin_password
echo "  OK: ArgoCD password set to '${ARGOCD_ADMIN_PASSWORD}'"

echo "  OK: ArgoCD configured"
echo ""

# --- Generate SOPS age key ---
echo "Step 6: Setting up SOPS encryption..."

# Check if age is installed on the host
if ! command -v age-keygen &>/dev/null; then
    echo "  ERROR: 'age' is not installed. Install with: brew install age (macOS) or apt install age (Linux)"
    exit 1
fi

# Generate a fresh age keypair
AGE_KEY_FILE="/tmp/age-key-remotelab-$$"
rm -f "$AGE_KEY_FILE"
age-keygen -o "$AGE_KEY_FILE" 2>/dev/null
AGE_PUBLIC_KEY=$(grep "public key:" "$AGE_KEY_FILE" | awk '{print $NF}')
AGE_PRIVATE_KEY=$(grep "AGE-SECRET-KEY" "$AGE_KEY_FILE")
echo "  Generated age keypair (public: ${AGE_PUBLIC_KEY:0:20}...)"

# Create the secret in argocd namespace for helm-secrets decryption
kubectl create secret generic sops-age-key \
    --namespace argocd \
    --from-file=key.txt="$AGE_KEY_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -

# Create the secret in applications namespace for the init job and scenario controller
kubectl create secret generic sops-age-key \
    --namespace applications \
    --from-file=key.txt="$AGE_KEY_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -

# Create a configmap with the public key (needed by init job and scenario controller)
kubectl create configmap sops-config \
    --namespace applications \
    --from-literal=age-public-key="$AGE_PUBLIC_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -

# Save the key locally for reference
mkdir -p "$REPO_DIR/secrets/keys"
cp "$AGE_KEY_FILE" "$REPO_DIR/secrets/keys/local.key"
rm "$AGE_KEY_FILE"

# Now configure ArgoCD SOPS (needs the secret to exist first)
kubectl apply -f "$REPO_DIR/manifests/gitops/argocd-sops-config.yaml"
echo "  Waiting for ArgoCD repo-server with SOPS tools..."
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s
echo "  OK: SOPS encryption configured"
echo "  Private key saved to: secrets/keys/local.key"
echo ""

# --- Deploy Infrastructure ---
echo "Step 7: Deploying PostgreSQL and Gitea..."
kubectl apply -f "$REPO_DIR/manifests/applications/postgresql.yaml"
kubectl apply -f "$REPO_DIR/manifests/applications/gitea.yaml"

echo "  Waiting for PostgreSQL..."
kubectl wait --for=condition=available --timeout=300s deployment/postgresql -n applications
echo "  Waiting for Gitea..."
kubectl wait --for=condition=available --timeout=300s deployment/gitea -n applications
echo "  OK: Infrastructure ready"
echo ""

# --- Ensure Traefik ---
echo "Step 8: Verifying Traefik ingress..."
if ! kubectl get deployment traefik -n kube-system &>/dev/null; then
    echo "  Installing Traefik via Helm..."
    if ! helm repo list 2>/dev/null | grep -q "^traefik"; then
        helm repo add traefik https://traefik.github.io/charts
    fi
    helm repo update traefik
    helm install traefik traefik/traefik \
        --namespace kube-system \
        --set service.type=LoadBalancer \
        --set ingressClass.enabled=true \
        --set ingressClass.isDefaultClass=true
    kubectl wait --for=condition=available --timeout=120s deployment/traefik -n kube-system
fi
echo "  OK: Traefik ready"
ensure_traefik_crds

# Apply ingress rules
kubectl apply -f "$REPO_DIR/manifests/infrastructure/"
echo ""

# --- Create Gitea user ---
echo "Step 9: Creating Gitea admin user..."
kubectl delete job gitea-init-user -n applications --ignore-not-found=true 2>/dev/null || true
sleep 2
kubectl apply -f "$REPO_DIR/manifests/applications/gitea-init-user.yaml"
kubectl wait --for=condition=complete --timeout=180s job/gitea-init-user -n applications 2>/dev/null || {
    echo "  WARNING: User creation may have had issues, continuing..."
}
echo "  OK: Gitea user ready (remotelab/remotelab)"
echo ""

# --- Initialize repository ---
echo "Step 10: Initializing Django app repository in Gitea..."

# Check for required tools
if ! command -v sops &>/dev/null; then
    echo "  ERROR: 'sops' is not installed on the host running this script"
    echo "         Step 10 encrypts the sample Django secrets locally before pushing them to Gitea."
    echo "         Install with: brew install sops (macOS), or use your Linux package manager / https://github.com/getsops/sops/releases"
    exit 1
fi

# Port-forward to Gitea for direct git access. Kept alive past script exit
# so the user can clone/push against http://localhost:3000 without restarting it.
# cleanup-all.sh removes it; re-running deploy-all.sh replaces it.
pkill -f "kubectl port-forward svc/gitea .* 3000:3000" 2>/dev/null || true
nohup kubectl port-forward svc/gitea -n applications 3000:3000 \
    >/tmp/argo-remotelab-gitea-pf.log 2>&1 &
PF_PID=$!
disown "$PF_PID"
sleep 3

# Create repo via API
REPO_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "remotelab:remotelab" \
    "http://localhost:3000/api/v1/repos/remotelab/django-app")

if [ "$REPO_CHECK" = "200" ]; then
    curl -s -X DELETE "http://localhost:3000/api/v1/repos/remotelab/django-app" \
        -u "remotelab:remotelab" > /dev/null
    sleep 2
fi

curl -s -X POST "http://localhost:3000/api/v1/user/repos" \
    -H "Content-Type: application/json" \
    -u "remotelab:remotelab" \
    -d '{"name":"django-app","description":"Django app with Helm chart and SOPS secrets","private":false,"auto_init":true,"default_branch":"main"}' > /dev/null
sleep 3

# Prepare local chart for push
WORK_DIR=$(mktemp -d)
cd "$WORK_DIR"
git init -q
git config user.email "remotelab@localhost"
git config user.name "Remotelab"

# Copy the Helm chart from local repo
cp -r "$REPO_DIR/sample-django-app/chart" .

# Create .sops.yaml
cat > chart/django-app/.sops.yaml <<SOPSEOF
creation_rules:
  - path_regex: '.*\.enc$'
    age: '$AGE_PUBLIC_KEY'
SOPSEOF

# Create and encrypt secrets
cat > /tmp/remotelab-secrets-plain.yaml <<SECRETSEOF
secrets:
  DB_PASSWORD: "remotelab"
  SECRET_KEY: "django-production-secret-key-argo-remotelab-2024"
  API_TOKEN: "tok_prod_abc123def456"
SECRETSEOF

export SOPS_AGE_KEY_FILE="$REPO_DIR/secrets/keys/local.key"
sops encrypt --age "$AGE_PUBLIC_KEY" --input-type yaml --output-type yaml \
    /tmp/remotelab-secrets-plain.yaml > chart/django-app/secrets.yaml.enc
rm -f /tmp/remotelab-secrets-plain.yaml

# Remove any stray packaged chart
rm -f chart/django-app-*.tgz

git add -A
git commit -q -m "Initial commit: Django app with Helm chart and SOPS secrets"
git remote add origin "http://remotelab:remotelab@localhost:3000/remotelab/django-app.git"
git push -f -u origin main -q 2>/dev/null

# Cleanup
cd "$REPO_DIR"
rm -rf "$WORK_DIR"

echo "  OK: Repository initialized with local Helm chart + SOPS secrets"
echo ""

# --- Create ArgoCD repo secret ---
echo "Step 11: Configuring ArgoCD repository access..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: gitea-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: http://gitea.applications.svc.cluster.local:3000/remotelab/django-app.git
  username: remotelab
  password: remotelab
EOF
echo "  OK: ArgoCD can access Gitea"
echo ""

# --- Deploy ArgoCD Application ---
echo "Step 12: Deploying ArgoCD Application..."
kubectl apply -f "$REPO_DIR/argocd-apps/django-app.yaml"
echo "  OK: ArgoCD Application created"
echo ""

# --- Wait for Django ---
echo "Step 13: Waiting for Django to be deployed by ArgoCD..."
MAX_WAIT=180
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if kubectl get deployment django -n applications &>/dev/null; then
        READY=$(kubectl get deployment django -n applications -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [ "${READY:-0}" -ge 1 ]; then
            echo "  OK: Django is running"
            break
        fi
    fi
    sleep 10
    WAIT_COUNT=$((WAIT_COUNT + 10))
    echo "  Waiting... (${WAIT_COUNT}s)"
done

if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    echo "  WARNING: Django not ready after ${MAX_WAIT}s"
    echo "  Check: kubectl get applications -n argocd django-app"
    echo "  Check: kubectl get pods -n applications"
fi
echo ""

# --- Build Scenario Controller Image ---
echo "Step 14: Building Scenario Controller image..."
if [[ "$OS" == "Darwin" ]]; then
    colima nerdctl -- build -t "$SCENARIO_CONTROLLER_IMAGE" \
        --namespace k8s.io "$REPO_DIR/scenario-controller" 2>&1 | tail -3
else
    # On Linux with k3s, use ctr to import
    if command -v nerdctl &>/dev/null; then
        nerdctl build -t "$SCENARIO_CONTROLLER_IMAGE" \
            --namespace k8s.io "$REPO_DIR/scenario-controller"
    else
        # Fallback: build with docker and import
        docker build -t "$SCENARIO_CONTROLLER_IMAGE" "$REPO_DIR/scenario-controller"
        docker save "$SCENARIO_CONTROLLER_IMAGE" | sudo k3s ctr images import -
    fi
fi
echo "  OK: Scenario controller image built"
echo ""

# --- Deploy Scenario Controller ---
echo "Step 15: Deploying Scenario Controller..."
kubectl apply -f "$REPO_DIR/manifests/applications/scenario-controller.yaml"
kubectl set image deployment/scenario-controller -n applications controller="$SCENARIO_CONTROLLER_IMAGE" >/dev/null
kubectl rollout restart deployment/scenario-controller -n applications >/dev/null
kubectl rollout status deployment/scenario-controller -n applications --timeout=180s
echo "  OK: Scenario controller deployed with the latest local image (will start injecting failures after app is healthy)"
echo ""

# --- Done ---
echo "========================================"
echo "  GitOps Failure Lab - Ready!"
echo "========================================"
echo ""
echo "Access:"
echo "  ArgoCD:     https://localhost/argocd"
echo "  Django:     https://localhost/django/api/health/"
echo ""
echo "Credentials:"
echo "  ArgoCD:  admin / ${ARGOCD_ADMIN_PASSWORD}"
echo ""
echo "SOPS Key: secrets/keys/local.key"
echo ""
echo "How it works:"
echo "  1. ArgoCD manages the Django app from Gitea (git source for Helm chart)"
echo "  2. The scenario controller watches ArgoCD health status"
echo "  3. When healthy, it randomly injects a failure (bad SOPS, missing ConfigMap, etc.)"
echo "  4. You troubleshoot using ArgoCD UI and kubectl"
echo "  5. Once you fix it, the controller logs an explanation and waits before the next failure"
echo ""
echo "Fix scenarios by cloning the lab repo, editing, and pushing:"
echo "  git clone http://remotelab:remotelab@localhost:3000/remotelab/django-app.git"
echo "  # for SOPS-encrypted files: export SOPS_AGE_KEY_FILE=${REPO_DIR}/secrets/keys/local.key"
echo "  (Gitea is reachable at http://localhost:3000 via a persistent port-forward; cleanup-all.sh removes it.)"
echo ""
echo "Useful commands:"
echo "  kubectl get applications -n argocd"
echo "  kubectl logs -n applications deployment/scenario-controller"
echo "  kubectl get pods -n applications"
echo ""
