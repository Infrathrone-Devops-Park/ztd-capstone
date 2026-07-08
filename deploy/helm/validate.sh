#!/usr/bin/env bash
# Offline validation gate for the ztd-capstone Helm chart.
#
# Runs, for each environment (dev/staging/prod):
#   1. helm lint
#   2. helm template | kubeconform (strict, ignore-missing-schemas for CRDs)
#   3. helm template (ServiceMonitor disabled, since the CRD schema is not
#      known to a plain client-side kubectl) | kubectl apply --dry-run=client
#
# This script performs NO cluster mutation: helm template only renders
# manifests locally, kubeconform validates schema via a local Docker image,
# and `kubectl apply --dry-run=client` never contacts an API server.
#
# Usage: deploy/helm/validate.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/ztd-capstone"
KUBECONFORM_IMAGE="ghcr.io/yannh/kubeconform:latest"
ENVS=(dev staging prod)

fail() {
  echo "VALIDATION FAILED: $*" >&2
  exit 1
}

echo "=== Step 1: helm lint (all envs) ==="
for env in "${ENVS[@]}"; do
  echo "--- lint: ${env} ---"
  helm lint "${CHART_DIR}" -f "${CHART_DIR}/values.yaml" -f "${CHART_DIR}/values-${env}.yaml" \
    || fail "helm lint failed for ${env}"
done

echo
echo "=== Step 2: helm template + kubeconform (all envs) ==="
for env in "${ENVS[@]}"; do
  echo "--- template+kubeconform: ${env} ---"
  rendered="$(mktemp)"
  helm template ztd "${CHART_DIR}" -f "${CHART_DIR}/values.yaml" -f "${CHART_DIR}/values-${env}.yaml" -n "${env}" \
    > "${rendered}" || fail "helm template failed for ${env}"

  docker run --rm -i "${KUBECONFORM_IMAGE}" -strict -ignore-missing-schemas -summary \
    < "${rendered}" || fail "kubeconform failed for ${env}"

  rm -f "${rendered}"
done

echo
echo "=== Step 2b: client-side dry-run (all envs, core kinds) ==="
# ServiceMonitor is a Prometheus Operator CRD; a plain client-side kubectl
# (no cluster/CRDs reachable) cannot resolve its schema, so it is excluded
# here — kubeconform above already validates it can render is skipped
# safely via -ignore-missing-schemas. All core kinds MUST dry-run clean.
for env in "${ENVS[@]}"; do
  echo "--- dry-run: ${env} ---"
  helm template ztd "${CHART_DIR}" -f "${CHART_DIR}/values.yaml" -f "${CHART_DIR}/values-${env}.yaml" \
    --set metrics.serviceMonitor.enabled=false -n "${env}" \
    | kubectl apply --dry-run=client -f - \
    || fail "kubectl dry-run failed for ${env}"
done

echo
echo "=== Step: prod-vs-dev assertions ==="
prod_rendered="$(helm template ztd "${CHART_DIR}" -f "${CHART_DIR}/values.yaml" -f "${CHART_DIR}/values-prod.yaml" -n prod)"
dev_rendered="$(helm template ztd "${CHART_DIR}" -f "${CHART_DIR}/values.yaml" -f "${CHART_DIR}/values-dev.yaml" -n dev)"

assert_count() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" -ne "${expected}" ]]; then
    fail "${desc}: expected ${expected}, got ${actual}"
  fi
  echo "OK: ${desc} = ${actual}"
}

assert_count "prod HPAs"                    4 "$(grep -c '^kind: HorizontalPodAutoscaler$' <<<"${prod_rendered}")"
assert_count "prod PDBs"                    4 "$(grep -c '^kind: PodDisruptionBudget$' <<<"${prod_rendered}")"
assert_count "prod ServiceMonitors"         4 "$(grep -c '^kind: ServiceMonitor$' <<<"${prod_rendered}")"
assert_count "prod default-deny NetworkPolicy" 1 "$(grep -c 'default-deny-ingress' <<<"${prod_rendered}")"
assert_count "prod Postgres StatefulSet"    1 "$(grep -c '^kind: StatefulSet$' <<<"${prod_rendered}")"
assert_count "prod Ingress"                 1 "$(grep -c '^kind: Ingress$' <<<"${prod_rendered}")"
assert_count "dev HPAs (must be 0)"         0 "$(grep -c '^kind: HorizontalPodAutoscaler$' <<<"${dev_rendered}")"
assert_count "dev PDBs (must be 0)"         0 "$(grep -c '^kind: PodDisruptionBudget$' <<<"${dev_rendered}")"

echo
echo "ALL VALIDATION CHECKS PASSED"
