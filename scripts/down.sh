#!/usr/bin/env bash
# Delete the kind cluster (all data, including PVCs, is lost).
source "$(dirname "$0")/lib.sh"
require_tools kind
if kind get clusters 2>/dev/null | grep -x "$CLUSTER_NAME" >/dev/null; then
  kind delete cluster --name "$CLUSTER_NAME"
else
  log "kind cluster ${CLUSTER_NAME} not found"
fi
