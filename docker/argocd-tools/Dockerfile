# syntax=docker/dockerfile:1
FROM alpine:3.19

ARG TARGETARCH
ARG HELM_SECRETS_VERSION=4.5.1
ARG SOPS_VERSION=3.8.1
ARG AGE_VERSION=1.1.1

RUN set -eux; \
    apk add --no-cache ca-certificates sed tar wget; \
    case "${TARGETARCH:-amd64}" in \
      amd64) arch="amd64" ;; \
      arm64) arch="arm64" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/argocd-tools/helm-plugins /opt/argocd-tools/bin /tmp/age; \
    wget -qO- "https://github.com/jkroepke/helm-secrets/releases/download/v${HELM_SECRETS_VERSION}/helm-secrets.tar.gz" \
      | tar xz -C /opt/argocd-tools/helm-plugins; \
    sed -i '/^platformCommand:/,/^[^ ]/{ /^platformCommand:/d; /^  /d; /^$/d; }' \
      /opt/argocd-tools/helm-plugins/helm-secrets/plugin.yaml; \
    wget -qO /opt/argocd-tools/bin/sops \
      "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${arch}"; \
    wget -qO- "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-${arch}.tar.gz" \
      | tar xz -C /tmp/age --strip-components=1; \
    cp /tmp/age/age /tmp/age/age-keygen /opt/argocd-tools/bin/; \
    chmod +x /opt/argocd-tools/bin/sops /opt/argocd-tools/bin/age /opt/argocd-tools/bin/age-keygen; \
    rm -rf /tmp/age
