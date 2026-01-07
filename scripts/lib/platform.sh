#!/bin/bash
# Platform detection and cross-platform utilities

detect_platform() {
    case "$(uname -s)" in
        Darwin*)  echo "macos" ;;
        Linux*)   echo "linux" ;;
        *)        echo "unknown" ;;
    esac
}

PLATFORM=$(detect_platform)

get_node_ip() {
    if [[ "$PLATFORM" == "macos" ]]; then
        ipconfig getifaddr en0 2>/dev/null || echo "127.0.0.1"
    else
        ip route get 1 2>/dev/null | awk '{print $7; exit}' || echo "127.0.0.1"
    fi
}

get_ram_gb() {
    if [[ "$PLATFORM" == "macos" ]]; then
        local bytes=$(sysctl -n hw.memsize 2>/dev/null)
        echo $((bytes / 1024 / 1024 / 1024))
    else
        free -g 2>/dev/null | awk '/^Mem:/{print $2}'
    fi
}

get_disk_space_gb() {
    if [[ "$PLATFORM" == "macos" ]]; then
        df -g / 2>/dev/null | awk 'NR==2{print $4}'
    else
        df / | awk 'NR==2{print int($4/1024/1024)}'
    fi
}

get_linkerd_path() {
    echo "${HOME}/.linkerd2/bin"
}

is_rancher_desktop() {
    [[ "$PLATFORM" == "macos" ]] && [[ -d "/Applications/Rancher Desktop.app" ]]
}

detect_local_context() {
    # Try to detect the local Kubernetes context
    # Returns the context name if found, empty string otherwise

    local contexts
    contexts=$(kubectl config get-contexts -o name 2>/dev/null || echo "")

    if [[ -z "$contexts" ]]; then
        echo ""
        return 1
    fi

    # Priority order for context detection:
    # 1. Exact match for common local cluster names
    # 2. Pattern match for variations
    # 3. Check current context if it looks local

    local patterns=(
        "^rancher-desktop$"
        "^rancher-desktop-k3s$"
        "rancher"
        "^docker-desktop$"
        "^colima$"
        "^k3d-"
        "^kind-"
        "^minikube$"
    )

    for pattern in "${patterns[@]}"; do
        local match
        match=$(echo "$contexts" | grep -E "$pattern" | head -n 1)
        if [[ -n "$match" ]]; then
            echo "$match"
            return 0
        fi
    done

    # Check if current context looks like a local cluster (not an ARN or remote URL)
    local current
    current=$(kubectl config current-context 2>/dev/null || echo "")
    if [[ -n "$current" ]] && [[ ! "$current" =~ ^arn: ]] && [[ ! "$current" =~ \. ]]; then
        echo "$current"
        return 0
    fi

    echo ""
    return 1
}

check_kubernetes_available() {
    kubectl cluster-info &>/dev/null 2>&1
}

switch_to_local_context() {
    log "Checking current kubectl context..."

    local current_context
    current_context=$(kubectl config current-context 2>/dev/null || echo "none")
    log "Current context: ${current_context}"

    local target_context
    if [[ "$PLATFORM" == "macos" ]]; then
        # Try to detect local context automatically
        target_context=$(detect_local_context)

        if [[ -z "$target_context" ]]; then
            error "No local Kubernetes context found in kubeconfig.

Available contexts:"
            kubectl config get-contexts 2>/dev/null || echo "  (none)"
            echo ""
            echo "Troubleshooting steps:"
            echo "  1. Ensure Rancher Desktop is installed and running"
            echo "  2. Open Rancher Desktop and go to Preferences"
            echo "  3. Enable 'Kubernetes' and wait for it to start"
            echo "  4. Verify with: kubectl config get-contexts"
            echo "  5. Look for a context like 'rancher-desktop' or 'rancher-desktop-k3s'"
            echo ""
            echo "If using a different local Kubernetes tool (Docker Desktop, Colima, etc.),"
            echo "ensure it's running and has created a kubeconfig context."
            return 1
        fi

        log "Detected local context: ${target_context}"
    else
        target_context="default"
    fi

    # Check if we're already on the right context
    if [[ "$current_context" == "$target_context" ]]; then
        log "Already using ${target_context} context"
        return 0
    fi

    # Check if target context exists
    if ! kubectl config get-contexts "$target_context" &>/dev/null; then
        warning "Context ${target_context} not found in kubeconfig"
        if [[ "$PLATFORM" == "linux" ]]; then
            warning "Will configure after k3s installation"
        fi
        return 1
    fi

    # Switch context
    log "Switching kubectl context to: ${target_context}"
    if kubectl config use-context "$target_context" &>/dev/null; then
        success "Successfully switched to ${target_context} context"

        # Verify the switch
        local new_context
        new_context=$(kubectl config current-context 2>/dev/null)
        log "Confirmed current context: ${new_context}"
        return 0
    else
        error "Failed to switch to ${target_context} context"
        return 1
    fi
}

log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Colors for output (needed for log functions)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
