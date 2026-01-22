# Cross-Platform Support Plan: MacOS + Linux

## Overview

Enable the k3s-remotelab project to work on both **MacOS** (via Colima with k3s) and **Linux** (native k3s), with auto-detection and support for existing setups.

> **Note**: This plan was originally written for Rancher Desktop but has been updated to use Colima, which provides a more reliable experience on macOS.

## Files to Modify

| File | Action | Purpose |
|------|--------|---------|
| `/scripts/lib/platform.sh` | **CREATE** | Cross-platform detection utilities |
| `/scripts/install-k3s.sh` | MODIFY | Add platform detection, macOS support |
| `/scripts/deploy-all.sh` | MODIFY | Remove hardcoded paths (lines 95, 310) |
| `/README.md` | MODIFY | Add macOS prerequisites |
| `/docs/CONTAINER_REGISTRY_SETUP.md` | MODIFY | Add macOS Docker config |

---

## Implementation Steps

### Step 1: Create `/scripts/lib/platform.sh`

New shared library with cross-platform helper functions:

```bash
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

is_colima() {
    [[ "$PLATFORM" == "macos" ]] && command -v colima &>/dev/null && colima status &>/dev/null
}

check_kubernetes_available() {
    kubectl cluster-info &>/dev/null 2>&1
}
```

---

### Step 2: Modify `/scripts/install-k3s.sh`

**Key changes:**

1. **Line 8**: Add `source "${SCRIPT_DIR}/lib/platform.sh"`

2. **Line 20**: Replace Linux-only IP detection:
   ```bash
   # OLD:
   NODE_IP=${NODE_IP:-$(ip route get 1 | awk '{print $7; exit}')}
   # NEW:
   NODE_IP=${NODE_IP:-$(get_node_ip)}
   ```

3. **Lines 49, 55**: Replace system resource checks:
   ```bash
   # OLD:
   RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
   DISK_GB=$(df / | awk 'NR==2{print int($4/1024/1024)}')
   # NEW:
   RAM_GB=$(get_ram_gb)
   DISK_GB=$(get_disk_space_gb)
   ```

4. **Add macOS setup function** (after `uninstall_k3s`):
   ```bash
   setup_macos() {
       log "Setting up for macOS with Colima..."

       if ! is_colima; then
           error "Colima not found or not running. Please install and start:
   brew install colima kubectl docker
   colima start --kubernetes --cpu 6 --memory 8 --disk 100
   export DOCKER_HOST=\"unix://\$HOME/.colima/default/docker.sock\"
   Then re-run this script"
       fi

       if ! check_kubernetes_available; then
           error "Kubernetes cluster not accessible. Ensure Colima is running with Kubernetes enabled."
       fi

       success "Colima Kubernetes cluster is ready"
       log "Skipping k3s installation (provided by Colima)"
   }
   ```

5. **Modify `configure_kubectl`**: Skip kubeconfig copy on macOS (Colima handles it)

6. **Modify `install_helm`**: Use Homebrew on macOS if available

7. **Modify `main`**: Add platform branching:
   ```bash
   if [[ "$PLATFORM" == "macos" ]]; then
       setup_macos
   elif [[ "$PLATFORM" == "linux" ]]; then
       check_prerequisites
       install_k3s
   else
       error "Unsupported platform: ${PLATFORM}"
   fi
   ```

---

### Step 3: Modify `/scripts/deploy-all.sh`

**Line 94-96**: Replace hardcoded path:
```bash
# OLD:
if ! command -v linkerd &> /dev/null; then
    export PATH=$PATH:/home/adam/.linkerd2/bin
fi

# NEW:
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/platform.sh"

if ! command -v linkerd &> /dev/null; then
    LINKERD_PATH=$(get_linkerd_path)
    if [[ -f "${LINKERD_PATH}/linkerd" ]]; then
        export PATH=$PATH:${LINKERD_PATH}
    fi
fi
```

**Line 310**: Replace hardcoded path in output:
```bash
# OLD:
echo "  - Check Linkerd dashboard: export PATH=\$PATH:/home/adam/.linkerd2/bin && ..."

# NEW:
echo "  - Check Linkerd dashboard: export PATH=\$PATH:$(get_linkerd_path) && ..."
```

---

### Step 4: Update `/README.md`

Add new section after line 25:

```markdown
## Platform Support

| Platform | Kubernetes Provider | Setup |
|----------|-------------------|-------|
| Linux (Ubuntu/Debian) | Native k3s | Automated via `install-k3s.sh` |
| macOS | Colima with k3s | Install Colima via Homebrew |

### macOS Prerequisites

1. Install Colima and dependencies:
   ```bash
   brew install colima kubectl docker
   ```
2. Start Colima with Kubernetes:
   ```bash
   colima start --kubernetes --cpu 6 --memory 8 --disk 100
   ```
3. Configure Docker environment:
   ```bash
   export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"
   ```
4. Verify cluster is ready:
   ```bash
   kubectl get nodes
   ```
```

---

### Step 5: Update `/docs/CONTAINER_REGISTRY_SETUP.md`

Add macOS section after existing Docker config (around line 55):

```markdown
#### macOS (Colima)

Colima uses containerd/k3s for the Kubernetes runtime. Configure registries via:

```bash
# SSH into Colima VM and configure registries
colima ssh -- sudo mkdir -p /etc/rancher/k3s
colima ssh -- sudo tee /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  localhost:
    endpoint:
      - "http://localhost"
EOF

# Restart k3s to apply changes
colima ssh -- sudo systemctl restart k3s
```

Note: Colima uses containerd, which handles registry configuration differently than Docker daemon.
```

---

## Testing Checklist

### Linux Testing
- [ ] Fresh Ubuntu VM - full install works
- [ ] Existing k3s - prompts for reinstall/skip
- [ ] `deploy-all.sh` completes successfully
- [ ] All services accessible

### macOS Testing
- [ ] Without Colima - helpful error message
- [ ] With Colima running - skips k3s install
- [ ] `deploy-all.sh` completes successfully
- [ ] All services accessible via localhost

---

## Notes

- Kubernetes manifests (`/manifests/**`) require **no changes** - they are platform-agnostic
- The `local-path` storage class works on both platforms (k3s built-in on Linux, Colima k3s on macOS)
- Linkerd service mesh works identically on both platforms
- All services remain accessible at `https://localhost/<path>`
