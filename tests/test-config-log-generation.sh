#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_config() {
  local level=$1
  local expected_level=$2
  local expected_access=$3
  local expected_dns_log=$4
  local tmpdir actual_level actual_access actual_dns_log

  tmpdir=$(mktemp -d)
  if [ "${level}" = "__unset__" ]; then
    env -u LOG_LEVEL XRAY_CONFIG_DIR="${tmpdir}" bash "${REPO_ROOT}/config.sh" >/dev/null
  else
    LOG_LEVEL="${level}" XRAY_CONFIG_DIR="${tmpdir}" bash "${REPO_ROOT}/config.sh" >/dev/null
  fi

  actual_level=$(jq -r '.log.loglevel' "${tmpdir}/config.json")
  actual_access=$(jq -r '.log.access' "${tmpdir}/config.json")
  actual_dns_log=$(jq -r '.log.dnsLog' "${tmpdir}/config.json")

  [[ "${actual_level}" == "${expected_level}" ]] || fail "expected loglevel ${expected_level} for ${level}, got ${actual_level}"
  [[ "${actual_access}" == "${expected_access}" ]] || fail "expected access ${expected_access} for ${level}, got ${actual_access}"
  [[ "${actual_dns_log}" == "${expected_dns_log}" ]] || fail "expected dnsLog ${expected_dns_log} for ${level}, got ${actual_dns_log}"
}

assert_config "__unset__" "info" "none" "false"
assert_config "info" "info" "none" "false"
assert_config "debug" "debug" "" "true"
assert_config "warning" "warning" "none" "false"
assert_config "warn" "warning" "none" "false"
assert_config "error" "error" "none" "false"
assert_config "none" "none" "none" "false"
assert_config "garbage" "info" "none" "false"

printf 'test-config-log-generation.sh passed.\n'
