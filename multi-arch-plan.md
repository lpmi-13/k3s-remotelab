# Cross-Platform Support Plan: MacOS + Linux

## Overview

Enable the k3s-remotelab project to work on both **MacOS** (via Rancher Desktop) and **Linux** (native k3s), with auto-detection and support for existing setups.

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

is_rancher_desktop() {
    [[ "$PLATFORM" == "macos" ]] && \
    (kubectl config current-context 2>/dev/null | grep -q "rancher-desktop" || \
     [[ -d "/Applications/Rancher Desktop.app" ]])
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
       log "Setting up for macOS with Rancher Desktop..."

       if ! is_rancher_desktop; then
           error "Rancher Desktop not found. Please install from https://rancherdesktop.io/
   After installation:
   1. Open Rancher Desktop
   2. Enable Kubernetes in Preferences
   3. Wait for cluster to be ready
   4. Re-run this script"
       fi

       if ! check_kubernetes_available; then
           error "Kubernetes cluster not accessible. Ensure Rancher Desktop is running with Kubernetes enabled."
       fi

       success "Rancher Desktop Kubernetes cluster is ready"
       log "Skipping k3s installation (provided by Rancher Desktop)"
   }
   ```

5. **Modify `configure_kubectl`**: Skip kubeconfig copy on macOS (Rancher Desktop handles it)

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
| macOS | Rancher Desktop | Install Rancher Desktop first |

### macOS Prerequisites

1. Install [Rancher Desktop](https://rancherdesktop.io/)
2. Launch and enable Kubernetes in Preferences
3. Allocate at least 4GB RAM in Preferences
4. Wait for green status (cluster ready)
5. Run `./scripts/install-k3s.sh`
```

---

### Step 5: Update `/docs/CONTAINER_REGISTRY_SETUP.md`

Add macOS section after existing Docker config (around line 55):

```markdown
#### macOS (Rancher Desktop)

Rancher Desktop manages Docker/containerd configuration through its UI:

1. Open Rancher Desktop Preferences
2. Navigate to Container Engine settings
3. Configure registry mirrors/insecure registries as needed
4. Restart Rancher Desktop to apply changes

Note: Rancher Desktop uses containerd by default, which handles registry
configuration differently than Docker daemon.
```

---

## Testing Checklist

### Linux Testing
- [ ] Fresh Ubuntu VM - full install works
- [ ] Existing k3s - prompts for reinstall/skip
- [ ] `deploy-all.sh` completes successfully
- [ ] All services accessible

### macOS Testing
- [ ] Without Rancher Desktop - helpful error message
- [ ] With Rancher Desktop running - skips k3s install
- [ ] `deploy-all.sh` completes successfully
- [ ] All services accessible via localhost

---

## Notes

- Kubernetes manifests (`/manifests/**`) require **no changes** - they are platform-agnostic
- The `local-path` storage class works on both platforms (k3s built-in on Linux, Rancher Desktop equivalent on macOS)
- Linkerd service mesh works identically on both platforms
- All services remain accessible at `https://localhost/<path>`
