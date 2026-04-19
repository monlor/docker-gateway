#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

source "${REPO_ROOT}/gateway-common.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack=$1
  local needle=$2

  [[ "${haystack}" == *"${needle}"* ]] || fail "expected output to contain '${needle}', got: ${haystack}"
}

assert_not_contains() {
  local haystack=$1
  local needle=$2

  [[ "${haystack}" != *"${needle}"* ]] || fail "expected output to omit '${needle}', got: ${haystack}"
}

capture_logs() {
  {
    docker_gateway_log "info-msg"
    docker_gateway_warn "warn-msg"
    docker_gateway_error "err-msg"
  } 2>&1
}

LOG_LEVEL=info
info_output=$(capture_logs)
assert_contains "${info_output}" "info-msg"
assert_contains "${info_output}" "WARN: warn-msg"
assert_contains "${info_output}" "ERROR: err-msg"

LOG_LEVEL=debug
debug_output=$(capture_logs)
assert_contains "${debug_output}" "info-msg"
assert_contains "${debug_output}" "WARN: warn-msg"
assert_contains "${debug_output}" "ERROR: err-msg"

LOG_LEVEL=warning
warning_output=$(capture_logs)
assert_not_contains "${warning_output}" "info-msg"
assert_contains "${warning_output}" "WARN: warn-msg"
assert_contains "${warning_output}" "ERROR: err-msg"

LOG_LEVEL=warn
warn_output=$(capture_logs)
assert_not_contains "${warn_output}" "info-msg"
assert_contains "${warn_output}" "WARN: warn-msg"
assert_contains "${warn_output}" "ERROR: err-msg"

LOG_LEVEL=error
error_output=$(capture_logs)
assert_not_contains "${error_output}" "info-msg"
assert_not_contains "${error_output}" "WARN: warn-msg"
assert_contains "${error_output}" "ERROR: err-msg"

LOG_LEVEL=none
none_output=$(capture_logs)
[[ -z "${none_output}" ]] || fail "expected no output for LOG_LEVEL=none, got: ${none_output}"

unset LOG_LEVEL
default_level=$(docker_gateway_normalized_log_level)
[[ "${default_level}" == "info" ]] || fail "expected default log level to normalize to info, got: ${default_level}"

LOG_LEVEL=warn
warn_level=$(docker_gateway_normalized_log_level)
[[ "${warn_level}" == "warning" ]] || fail "expected warn alias to normalize to warning, got: ${warn_level}"

LOG_LEVEL=garbage
invalid_level=$(docker_gateway_normalized_log_level)
[[ "${invalid_level}" == "info" ]] || fail "expected invalid log level to normalize to info, got: ${invalid_level}"

printf 'test-log-levels.sh passed.\n'
