#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

source "${REPO_ROOT}/gateway-common.sh"
eval "$(tail -n +7 "${REPO_ROOT}/docker-gateway-manager.sh" | sed '$d')"

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

docker() {
  if [ "$1" = inspect ]; then
    cat <<JSON
[
  {
    "Id": "container1234567890",
    "Name": "/demo",
    "State": {"Pid": 1234},
    "HostConfig": {"NetworkMode": "default"},
    "Config": {
      "Labels": {
        "docker-gateway.gateway": "main",
        "docker-gateway.proxy": "${TEST_PROXY_SPEC}",
        "docker-gateway.dns-servers": "8.8.8.8",
        "docker-gateway.dns-mode": "${TEST_DNS_MODE}"
      }
    },
    "NetworkSettings": {
      "Networks": {
        "frontend": {"IPAddress": "172.18.0.10"}
      }
    }
  }
]
JSON
    return 0
  fi

  command docker "$@"
}

run_manage_container() {
  local stderr_file=$1

  manage_container container1234567890 frontend 172.18.0.1 plan 2>"${stderr_file}"
}

warning_text="HTTP proxy outbound only carries TCP. Proxied DNS for demo (container123) may fail for normal UDP/53 queries."

TEST_PROXY_SPEC="http,1.2.3.4:8080"
TEST_DNS_MODE="proxy"
LOG_LEVEL=info
stderr_file=$(mktemp)
json_output=$(run_manage_container "${stderr_file}")
stderr_output=$(cat "${stderr_file}")

assert_contains "${stderr_output}" "${warning_text}"
assert_contains "$(jq -r '.reasons[]' <<<"${json_output}")" "${warning_text}"
[[ "$(jq -r '.effective_dns_mode' <<<"${json_output}")" == "proxy" ]] || fail "expected effective_dns_mode=proxy"

LOG_LEVEL=error
stderr_file=$(mktemp)
json_output=$(run_manage_container "${stderr_file}")
stderr_output=$(cat "${stderr_file}")

[[ -z "${stderr_output}" ]] || fail "expected warning stderr to be suppressed at LOG_LEVEL=error, got: ${stderr_output}"
assert_contains "$(jq -r '.reasons[]' <<<"${json_output}")" "${warning_text}"

TEST_PROXY_SPEC="socks,1.2.3.4:1080"
TEST_DNS_MODE="proxy"
LOG_LEVEL=info
stderr_file=$(mktemp)
json_output=$(run_manage_container "${stderr_file}")
stderr_output=$(cat "${stderr_file}")

assert_not_contains "${stderr_output}" "${warning_text}"
assert_not_contains "$(jq -r '.reasons[]' <<<"${json_output}")" "${warning_text}"

TEST_PROXY_SPEC="http,1.2.3.4:8080"
TEST_DNS_MODE="direct"
stderr_file=$(mktemp)
json_output=$(run_manage_container "${stderr_file}")
stderr_output=$(cat "${stderr_file}")

assert_not_contains "${stderr_output}" "${warning_text}"
assert_not_contains "$(jq -r '.reasons[]' <<<"${json_output}")" "${warning_text}"

printf 'test-manager-warning.sh passed.\n'
