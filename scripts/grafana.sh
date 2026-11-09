#!/usr/bin/env bash
# Port-forward Grafana to http://localhost:${GRAFANA_PORT:-3000} and print the admin password.
source "$(dirname "$0")/lib.sh"
port="${GRAFANA_PORT:-3000}"
pw="$(k -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
log "Grafana: http://localhost:${port}  user=admin  password=${pw}"
exec kubectl --context "$KCTX" -n monitoring port-forward svc/vmks-grafana "${port}:80"
