#!/usr/bin/env bash
set -euo pipefail

namespace="${ARGOCD_NAMESPACE:-argocd}"
app_name="${ARGOCD_APP_NAME:-django-app}"
timeout_seconds="${FIRST_SCENARIO_TIMEOUT_SECONDS:-300}"
ready_annotation="remotelab.io/first-scenario-ready"

for cmd in kubectl jq date; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "error: required command not found: ${cmd}" >&2
        exit 1
    fi
done

if [[ ! "${timeout_seconds}" =~ ^[0-9]+$ ]]; then
    echo "error: FIRST_SCENARIO_TIMEOUT_SECONDS must be a non-negative integer" >&2
    exit 1
fi

deadline=$(($(date +%s) + timeout_seconds))

while true; do
    if kubectl -n "${namespace}" get application "${app_name}" -o json 2>/dev/null | jq -e --arg ready_annotation "${ready_annotation}" '
        .metadata.annotations[$ready_annotation] == "true"
        and (
            (.status.health.status // "Unknown") != "Healthy"
            or (.status.sync.status // "Unknown") != "Synced"
            or (.status.operationState.phase // "") == "Running"
        )
    ' >/dev/null; then
        exit 0
    fi

    if (( $(date +%s) >= deadline )); then
        echo "timed out waiting for ${namespace}/${app_name} to report the first injected scenario" >&2
        kubectl -n "${namespace}" get application "${app_name}" -o json 2>/dev/null | jq '{
            annotations: .metadata.annotations,
            health: .status.health.status,
            sync: .status.sync.status,
            operation: .status.operationState.phase
        }' >&2 || true
        exit 1
    fi

    sleep 2
done
