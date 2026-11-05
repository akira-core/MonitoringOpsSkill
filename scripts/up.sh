#!/usr/bin/env bash
# Bring up the whole lab on kind. Idempotent: safe to re-run.
source "$(dirname "$0")/lib.sh"
require_tools kind kubectl helm docker openssl

create_cluster() {
  if kind get clusters 2>/dev/null | grep -x "$CLUSTER_NAME" >/dev/null; then
    log "kind cluster ${CLUSTER_NAME} exists"
  else
    log "creating kind cluster ${CLUSTER_NAME}"
    kind create cluster --config "${ROOT_DIR}/kind/cluster.yaml"
  fi
  k wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
}

helm_repos() {
  log "helm repos"
  helm repo add vm https://victoriametrics.github.io/helm-charts/ >/dev/null 2>&1 || true
  helm repo add altinity https://helm.altinity.com >/dev/null 2>&1 || true
  helm repo add fluent https://fluent.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
  helm repo add vector https://helm.vector.dev >/dev/null 2>&1 || true
  helm repo update vm altinity fluent kedacore vector >/dev/null
}

namespaces_and_secrets() {
  local ns
  for ns in monitoring clickhouse logging vmagent-lab vector-lab keda; do
    k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null
  done

  # ClickHouse writer password shared by ClickHouse (user otel) and rotel (logging).
  local ch_pw
  if k -n clickhouse get secret clickhouse-otel >/dev/null 2>&1; then
    ch_pw="$(k -n clickhouse get secret clickhouse-otel -o jsonpath='{.data.password}' | base64 -d)"
  else
    ch_pw="$(gen_password)"
  fi
  for ns in clickhouse logging; do
    ensure_secret "$ns" clickhouse-otel --from-literal=username=otel --from-literal=password="$ch_pw"
  done

  # Separate read-only ClickHouse user for Grafana (never the writer credential).
  local gf_ch_pw
  if k -n clickhouse get secret clickhouse-grafana >/dev/null 2>&1; then
    gf_ch_pw="$(k -n clickhouse get secret clickhouse-grafana -o jsonpath='{.data.password}' | base64 -d)"
  else
    gf_ch_pw="$(gen_password)"
  fi
  for ns in clickhouse monitoring; do
    ensure_secret "$ns" clickhouse-grafana --from-literal=username=grafana --from-literal=password="$gf_ch_pw"
  done
  ensure_secret monitoring grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$(gen_password)"
}

install_vm_stack() {
  log "victoria-metrics-k8s-stack ${VM_K8S_STACK_VERSION}"
  h upgrade --install vmks vm/victoria-metrics-k8s-stack --version "$VM_K8S_STACK_VERSION" \
    -n monitoring -f "${ROOT_DIR}/helm/values/vm-k8s-stack.yaml"
  wait_rollout monitoring deploy vmks-victoria-metrics-operator
  wait_jsonpath monitoring vmcluster/vmks '{.status.updateStatus}' operational 600
  wait_jsonpath monitoring vmagent/vmks '{.status.updateStatus}' operational 300
  wait_rollout monitoring deploy vmks-grafana 600s
}

install_clickhouse() {
  log "altinity-clickhouse-operator ${CLICKHOUSE_OPERATOR_VERSION}"
  h upgrade --install clickhouse-operator altinity/altinity-clickhouse-operator \
    --version "$CLICKHOUSE_OPERATOR_VERSION" -n clickhouse \
    -f "${ROOT_DIR}/helm/values/clickhouse-operator.yaml" --wait --timeout 5m
  k apply -k "${ROOT_DIR}/manifests/clickhouse"
  wait_jsonpath clickhouse chi/logs '{.status.status}' Completed 600

  log "creating otel tables with rotel-clickhouse-ddl"
  k -n clickhouse delete job rotel-clickhouse-ddl --ignore-not-found >/dev/null
  k apply -f "${ROOT_DIR}/manifests/clickhouse/rotel-ddl-job.yaml"
  k -n clickhouse wait --for=condition=complete job/rotel-clickhouse-ddl --timeout=300s
}

install_logging() {
  log "rotel + vector ${VECTOR_VERSION} + fluent-bit ${FLUENT_BIT_VERSION}"
  k apply -k "${ROOT_DIR}/manifests/logging"
  wait_rollout logging deploy rotel
  h upgrade --install vector vector/vector --version "$VECTOR_VERSION" \
    -n logging -f "${ROOT_DIR}/helm/values/vector.yaml"
  wait_rollout logging sts vector 600s
  h upgrade --install fluent-bit fluent/fluent-bit --version "$FLUENT_BIT_VERSION" \
    -n logging -f "${ROOT_DIR}/helm/values/fluent-bit.yaml"
  wait_rollout logging ds fluent-bit
}

install_keda() {
  log "keda ${KEDA_VERSION}"
  h upgrade --install keda kedacore/keda --version "$KEDA_VERSION" -n keda --wait --timeout 5m
}

install_vmagent_lab() {
  log "vmagent autoscale lab"
  k apply -k "${ROOT_DIR}/manifests/vmagent-lab"
  wait_rollout vmagent-lab deploy avalanche
  wait_jsonpath vmagent-lab vmagent/lab '{.status.updateStatus}' operational 300
}

install_vector_lab() {
  log "vector autoscale lab"
  k apply -k "${ROOT_DIR}/manifests/vector-lab"
  wait_rollout vector-lab deploy loggen
}

install_dashboards() {
  log "grafana dashboards"
  k apply -k "${ROOT_DIR}/manifests/dashboards"
}

main() {
  create_cluster
  helm_repos
  namespaces_and_secrets
  install_vm_stack
  install_clickhouse
  install_logging
  install_keda
  install_vmagent_lab
  install_vector_lab
  install_dashboards
  log "done. Grafana: make grafana  (port-forward localhost:3000, prints the admin password)"
}

main "$@"
