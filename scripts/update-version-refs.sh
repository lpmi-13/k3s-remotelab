#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_image_tag=""
rootfs_image=""

usage() {
  cat <<'EOF'
Usage: scripts/update-version-refs.sh [OPTIONS]

Options:
  --repo-root <path>        Repository root to update. Defaults to this checkout.
  --app-image-tag <tag>     Update first-party image tags.
  --rootfs-image <image>    Update iximiuz rootfs image reference.
  --help, -h               Show this help.
EOF
}

escape_sed_replacement() {
  printf '%s' "$1" | sed 's#[/&]#\\&#g'
}

validate_tag() {
  local tag="$1"

  if [[ ! "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
    echo "error: invalid image tag '${tag}'." >&2
    exit 1
  fi
}

normalize_rootfs_image() {
  local image="$1"

  if [[ "${image}" == oci://* ]]; then
    image="${image#oci://}"
  fi

  if [[ -z "${image}" ]]; then
    echo "error: rootfs image cannot be empty." >&2
    exit 1
  fi

  printf '%s\n' "${image}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      shift
      [[ $# -gt 0 ]] || { echo "error: --repo-root requires a value." >&2; exit 1; }
      repo_root="$1"
      ;;
    --app-image-tag)
      shift
      [[ $# -gt 0 ]] || { echo "error: --app-image-tag requires a value." >&2; exit 1; }
      app_image_tag="$1"
      ;;
    --rootfs-image)
      shift
      [[ $# -gt 0 ]] || { echo "error: --rootfs-image requires a value." >&2; exit 1; }
      rootfs_image="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option '$1'." >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ -z "${app_image_tag}" && -z "${rootfs_image}" ]]; then
  echo "error: pass at least one of --app-image-tag or --rootfs-image." >&2
  exit 1
fi

versions_file="${repo_root}/scripts/lib/versions.sh"
django_values="${repo_root}/sample-django-app/chart/django-app/values.yaml"
scenario_controller_manifest="${repo_root}/manifests/applications/scenario-controller.yaml"
argocd_tools_manifest="${repo_root}/playground/iximiuz/manifests/argocd-sops-config-preloaded.yaml"
playground_manifest="${repo_root}/playground/iximiuz/manifest.yaml"

if [[ -n "${app_image_tag}" ]]; then
  validate_tag "${app_image_tag}"
  escaped_tag="$(escape_sed_replacement "${app_image_tag}")"

  for file in "${versions_file}" "${django_values}" "${scenario_controller_manifest}" "${argocd_tools_manifest}"; do
    test -f "${file}" || { echo "error: missing file ${file}." >&2; exit 1; }
  done

  sed -E -i \
    "s#^(readonly DEFAULT_FIRST_PARTY_IMAGE_TAG=\").*(\")#\1${escaped_tag}\2#" \
    "${versions_file}"
  sed -E -i \
    "s#^([[:space:]]*tag: ).*#\1${escaped_tag}#" \
    "${django_values}"
  sed -E -i \
    "s#(ghcr\.io/lpmi-13/argo-remotelab-scenario-controller:)[A-Za-z0-9_.-]+#\1${escaped_tag}#" \
    "${scenario_controller_manifest}"
  sed -E -i \
    "s#(ghcr\.io/lpmi-13/argo-remotelab-argocd-tools:)[A-Za-z0-9_.-]+#\1${escaped_tag}#" \
    "${argocd_tools_manifest}"
fi

if [[ -n "${rootfs_image}" ]]; then
  rootfs_image="$(normalize_rootfs_image "${rootfs_image}")"
  escaped_rootfs="$(escape_sed_replacement "${rootfs_image}")"
  escaped_manifest_source="$(escape_sed_replacement "oci://${rootfs_image}")"

  for file in "${versions_file}" "${playground_manifest}"; do
    test -f "${file}" || { echo "error: missing file ${file}." >&2; exit 1; }
  done

  sed -E -i \
    "s#^(readonly DEFAULT_IXIMIUZ_ROOTFS_IMAGE=\").*(\")#\1${escaped_rootfs}\2#" \
    "${versions_file}"
  sed -E -i \
    "s#^([[:space:]]*- source: ).*#\1${escaped_manifest_source}#" \
    "${playground_manifest}"
fi

echo "Updated version references:"
if [[ -n "${app_image_tag}" ]]; then
  echo "  app image tag: ${app_image_tag}"
fi
if [[ -n "${rootfs_image}" ]]; then
  echo "  rootfs image: ${rootfs_image}"
fi
