#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
source "${SCRIPT_DIR}/gateway-common.sh"

docker_gateway_require_socket

gateway_context=$(docker_gateway_resolve_context)
DOCKER_GATEWAY_CONTAINER_ID=$(jq -r '.container_id' <<<"${gateway_context}")
DOCKER_GATEWAY_NAME=$(jq -r '.gateway_name' <<<"${gateway_context}")
DOCKER_GATEWAY_ATTACH_NETWORK=$(jq -r '.attach_network' <<<"${gateway_context}")
DOCKER_GATEWAY_IP=$(jq -r '.gateway_ip' <<<"${gateway_context}")
DOCKER_GATEWAY_SUBNET=$(jq -r '.gateway_subnet' <<<"${gateway_context}")

export DOCKER_GATEWAY_CONTAINER_ID
export DOCKER_GATEWAY_NAME
export DOCKER_GATEWAY_ATTACH_NETWORK
export DOCKER_GATEWAY_IP
export DOCKER_GATEWAY_SUBNET
export XRAY_API_SERVER=${XRAY_API_SERVER:-127.0.0.1:${XRAY_API_PORT:-10085}}

if ! docker_gateway_validate_unique_name "${DOCKER_GATEWAY_NAME}" "${DOCKER_GATEWAY_CONTAINER_ID}"; then
  docker_gateway_warn "Another running gateway uses the same logical name. Xray will start, but container sync will be skipped until labels are unique."
fi

docker_gateway_log "Gateway logical name: ${DOCKER_GATEWAY_NAME}"
docker_gateway_log "Gateway attach network: ${DOCKER_GATEWAY_ATTACH_NETWORK}"
docker_gateway_log "Gateway network IP: ${DOCKER_GATEWAY_IP}"
docker_gateway_log "Gateway subnet: ${DOCKER_GATEWAY_SUBNET}"

IPTABLES=$(docker_gateway_detect_iptables_command "${IPTABLES_COMMAND:-}") || {
  docker_gateway_error "Unable to find a working iptables binary. Set IPTABLES_COMMAND to a valid command."
  exit 1
}
export IPTABLES_COMMAND="${IPTABLES}"

docker_gateway_log "Generating iptables rules."

ip rule show | grep -q 'fwmark 0x1 lookup 100' || ip rule add fwmark 1 table 100
table_100_routes=$(ip route show table 100 2>/dev/null || true)
printf '%s\n' "${table_100_routes}" | grep -q '^local 0.0.0.0/0 dev lo' || ip route add local 0.0.0.0/0 dev lo table 100

${IPTABLES} -t mangle -N XRAY 2>/dev/null || true
${IPTABLES} -t mangle -F XRAY
${IPTABLES} -t mangle -A XRAY -d 127.0.0.1/24 -j RETURN
${IPTABLES} -t mangle -A XRAY -d 224.0.0.0/4 -j RETURN
${IPTABLES} -t mangle -A XRAY -d 255.255.255.255/32 -j RETURN
${IPTABLES} -t mangle -A XRAY -d "${DOCKER_GATEWAY_SUBNET}" -p tcp -j RETURN
${IPTABLES} -t mangle -A XRAY -d "${DOCKER_GATEWAY_SUBNET}" -p udp ! --dport 53 -j RETURN
${IPTABLES} -t mangle -A XRAY -j RETURN -m mark --mark 0xff
${IPTABLES} -t mangle -A XRAY -p udp -j TPROXY --on-ip 127.0.0.1 --on-port "${PORT:-12345}" --tproxy-mark 1
${IPTABLES} -t mangle -A XRAY -p tcp -j TPROXY --on-ip 127.0.0.1 --on-port "${PORT:-12345}" --tproxy-mark 1
${IPTABLES} -t mangle -C PREROUTING -j XRAY 2>/dev/null || ${IPTABLES} -t mangle -A PREROUTING -j XRAY

if [ "${LOCAL_PROXY_ENABLED:-false}" = "true" ]; then
  ${IPTABLES} -t mangle -N XRAY_MASK 2>/dev/null || true
  ${IPTABLES} -t mangle -F XRAY_MASK
  ${IPTABLES} -t mangle -A XRAY_MASK -d 127.0.0.1/24 -j RETURN
  ${IPTABLES} -t mangle -A XRAY_MASK -d 224.0.0.0/4 -j RETURN
  ${IPTABLES} -t mangle -A XRAY_MASK -d 255.255.255.255/32 -j RETURN
  ${IPTABLES} -t mangle -A XRAY_MASK -d "${DOCKER_GATEWAY_SUBNET}" -p tcp -j RETURN
  ${IPTABLES} -t mangle -A XRAY_MASK -d "${DOCKER_GATEWAY_SUBNET}" -p udp ! --dport 53 -j RETURN
  ${IPTABLES} -t mangle -A XRAY_MASK -j RETURN -m mark --mark 0xff
  ${IPTABLES} -t mangle -A XRAY_MASK -p udp -j MARK --set-mark 1
  ${IPTABLES} -t mangle -A XRAY_MASK -p tcp -j MARK --set-mark 1
  ${IPTABLES} -t mangle -C OUTPUT -j XRAY_MASK 2>/dev/null || ${IPTABLES} -t mangle -A OUTPUT -j XRAY_MASK
fi

${IPTABLES} -t mangle -N DIVERT 2>/dev/null || true
${IPTABLES} -t mangle -F DIVERT
${IPTABLES} -t mangle -A DIVERT -j MARK --set-mark 1
${IPTABLES} -t mangle -A DIVERT -j ACCEPT
${IPTABLES} -t mangle -C PREROUTING -p tcp -m socket -j DIVERT 2>/dev/null || ${IPTABLES} -t mangle -I PREROUTING -p tcp -m socket -j DIVERT

docker_gateway_log "Generating Xray config."
/config.sh

docker_gateway_log "Starting gateway manager."
/docker-gateway-manager.sh &

docker_gateway_log "Starting Xray."
exec xray -config "${XRAY_CONFIG_DIR:-/etc/xray}/config.json"
