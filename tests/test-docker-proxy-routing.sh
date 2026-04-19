#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

IMAGE_NAME=${TEST_IMAGE_NAME:-docker-gateway:test}
TEST_PROXY_SPEC=${TEST_PROXY_SPEC:-socks,192.168.100.5:6153}
MOCK_PROXY_IMAGE=${MOCK_PROXY_IMAGE:-serjs/go-socks5-proxy}

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

cleanup() {
  docker rm -f "${APP_CONTAINER}" "${GATEWAY_CONTAINER}" "${PROXY_CONTAINER}" >/dev/null 2>&1 || true
  docker network rm "${TEST_NETWORK}" >/dev/null 2>&1 || true
}

proxy_reachable() {
  local proxy_protocol proxy_host proxy_port
  IFS=',' read -r proxy_protocol proxy_host proxy_port _ <<<"${TEST_PROXY_SPEC}"

  [ "${proxy_protocol}" = "socks" ] || return 1
  [[ "${proxy_port}" =~ ^[0-9]+$ ]] || return 1

  python3 - "${proxy_host}" "${proxy_port}" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])

s = socket.socket()
s.settimeout(2)
try:
    s.connect((host, port))
    s.sendall(b"\x05\x01\x00")
    reply = s.recv(2)
except Exception:
    sys.exit(1)
finally:
    s.close()

sys.exit(0 if reply == b"\x05\x00" else 1)
PY
}

wait_for_status() {
  local expected_status=$1
  local status_json current_status

  for _ in $(seq 1 30); do
    status_json=$(docker exec "${GATEWAY_CONTAINER}" /docker-gateway-manager.sh --status 2>/dev/null || true)
    current_status=$(jq -r '.status // empty' <<<"${status_json}")
    if [ "${current_status}" = "${expected_status}" ]; then
      printf '%s\n' "${status_json}"
      return 0
    fi
    sleep 1
  done

  docker exec "${GATEWAY_CONTAINER}" /docker-gateway-manager.sh --status 2>/dev/null || true
  return 1
}

wait_for_log_line() {
  local needle=$1
  local logs

  for _ in $(seq 1 30); do
    logs=$(docker logs "${GATEWAY_CONTAINER}" 2>&1 || true)
    if [[ "${logs}" == *"${needle}"* ]]; then
      printf '%s\n' "${logs}"
      return 0
    fi
    sleep 1
  done

  docker logs "${GATEWAY_CONTAINER}" 2>&1 || true
  return 1
}

TEST_NETWORK="docker-gateway-test-${RANDOM}"
GATEWAY_CONTAINER="docker-gateway-gw-${RANDOM}"
APP_CONTAINER="docker-gateway-app-${RANDOM}"
PROXY_CONTAINER=""
trap cleanup EXIT

docker build -t "${IMAGE_NAME}" "${REPO_ROOT}" >/dev/null
docker network create "${TEST_NETWORK}" >/dev/null

if ! proxy_reachable; then
  PROXY_CONTAINER="docker-gateway-proxy-${RANDOM}"
  docker run -d --name "${PROXY_CONTAINER}" --network "${TEST_NETWORK}" "${MOCK_PROXY_IMAGE}" >/dev/null
  TEST_PROXY_SPEC="socks,${PROXY_CONTAINER}:1080"
fi

docker run -d \
  --name "${GATEWAY_CONTAINER}" \
  --network "${TEST_NETWORK}" \
  --label docker-gateway.name=main \
  --label docker-gateway.attach-network="${TEST_NETWORK}" \
  --privileged=true \
  --pid=host \
  -e LOG_LEVEL=debug \
  -v /var/run/docker.sock:/var/run/docker.sock \
  "${IMAGE_NAME}" >/dev/null

docker run -d \
  --name "${APP_CONTAINER}" \
  --network "${TEST_NETWORK}" \
  --label docker-gateway.gateway=main \
  --label docker-gateway.proxy="${TEST_PROXY_SPEC}" \
  alpine:latest sleep 180 >/dev/null

status_json=$(wait_for_status "applied") || fail "gateway manager did not reach applied status"
assert_not_contains "${status_json}" "dynamic routing sync failed"

docker exec "${APP_CONTAINER}" sh -lc "printf 'GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n' | nc -w 10 example.com 80 >/dev/null" || fail "test app failed to send an HTTP request through the gateway"

gateway_logs=$(wait_for_log_line 'taking detour [docker-gateway-proxy-') || fail "gateway logs did not show proxy detour"
assert_not_contains "${gateway_logs}" "FIB table does not exist"

printf 'test-docker-proxy-routing.sh passed.\n'
