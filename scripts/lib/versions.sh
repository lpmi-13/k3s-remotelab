#!/usr/bin/env bash

readonly DEFAULT_FIRST_PARTY_IMAGE_TAG="v1"
readonly ROOTFS_IMAGE_REPO="ghcr.io/lpmi-13/argo-remotelab-k3s-rootfs"
readonly DEFAULT_IXIMIUZ_ROOTFS_IMAGE="ghcr.io/lpmi-13/argo-remotelab-k3s-rootfs:v1"
readonly DEFAULT_IXIMIUZ_ROOTFS_RELEASE="e2771a49"

readonly DJANGO_IMAGE_REPO="ghcr.io/lpmi-13/argo-remotelab-django"
readonly SCENARIO_CONTROLLER_IMAGE_REPO="ghcr.io/lpmi-13/argo-remotelab-scenario-controller"
readonly ARGOCD_TOOLS_IMAGE_REPO="ghcr.io/lpmi-13/argo-remotelab-argocd-tools"

readonly POSTGRES_IMAGE="postgres:16"
readonly GITEA_IMAGE="gitea/gitea:1.22"
readonly GITEA_ADMIN_IMAGE="gitea/gitea:1.20"
readonly BUSYBOX_IMAGE="busybox:1.36.1"
