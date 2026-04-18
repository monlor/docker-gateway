#!/bin/bash
set -euo pipefail

source /gateway-common.sh

XRAY_CONFIG_DIR=${XRAY_CONFIG_DIR:-/etc/xray}
XRAY_CONFIG_PATH="${XRAY_CONFIG_DIR}/config.json"
XRAY_DEFAULT_RULE_PATH="${XRAY_CONFIG_DIR}/default-routing-rule.json"
XRAY_API_SERVER=${XRAY_API_SERVER:-127.0.0.1:${XRAY_API_PORT:-10085}}
GATEWAY_STATE_DIR=${GATEWAY_STATE_DIR:-/run/docker-gateway}
XRAY_DYNAMIC_RULE_TAGS_FILE="${GATEWAY_STATE_DIR}/dynamic-rule-tags"
RULE_DOMAIN_JSON=$(jq -nc --arg domains "${RULE_DOMAIN:-}" 'if $domains == "" then [] else ($domains | split(",") | map(select(length > 0))) end')

wait_for_xray_api() {
  local host port attempt

  host=${XRAY_API_SERVER%:*}
  port=${XRAY_API_SERVER##*:}

  for attempt in $(seq 1 30); do
    if exec 3<>"/dev/tcp/${host}/${port}" 2>/dev/null; then
      exec 3>&-
      exec 3<&-
      return 0
    fi

    docker_gateway_log "Waiting for Xray API on ${XRAY_API_SERVER} (${attempt}/30)"
    sleep 1
  done

  docker_gateway_error "Timed out waiting for Xray API on ${XRAY_API_SERVER}."
  return 1
}

xray_outbound_exists() {
  local outbound_tag=$1

  jq -e --arg tag "${outbound_tag}" '.outbounds[] | select(.tag == $tag)' "${XRAY_CONFIG_PATH}" >/dev/null
}

build_dynamic_rule_json() {
  local container_id=$1
  local container_ip=$2
  local outbound_tag=$3

  jq -n \
    --arg rule_tag "docker-gateway-${container_id:0:12}" \
    --arg source_ip "${container_ip}/32" \
    --arg outbound_tag "${outbound_tag}" \
    --argjson domains "${RULE_DOMAIN_JSON}" \
    '{
      ruleTag: $rule_tag,
      type: "field",
      source: [$source_ip],
      outboundTag: $outbound_tag
    } + (if ($domains | length) > 0 then {domain: $domains} else {} end)'
}

render_dynamic_routing_config_file() {
  local output_file=$1
  shift
  local dynamic_rules=("$@")
  local dynamic_rules_json

  if [ "${#dynamic_rules[@]}" -gt 0 ]; then
    dynamic_rules_json=$(printf '%s\n' "${dynamic_rules[@]}" | jq -s '.')
  else
    dynamic_rules_json='[]'
  fi

  jq -n \
    --argjson dynamic_rules "${dynamic_rules_json}" \
    --slurpfile default_rule "${XRAY_DEFAULT_RULE_PATH}" \
    '{
      routing: {
        rules: ($dynamic_rules + [$default_rule[0]])
      }
    }' > "${output_file}"
}

sync_xray_routing() {
  local dynamic_rules=("$@")
  local temp_file
  local -a previous_rule_tags current_rule_tags
  local rule_json

  if [ -f "${XRAY_DYNAMIC_RULE_TAGS_FILE}" ]; then
    mapfile -t previous_rule_tags < "${XRAY_DYNAMIC_RULE_TAGS_FILE}"
  fi

  if [ "${#previous_rule_tags[@]}" -gt 0 ]; then
    if ! xray api rmrules --server="${XRAY_API_SERVER}" "${previous_rule_tags[@]}"; then
      docker_gateway_error "Failed to remove previous dynamic routing rules."
      return 1
    fi
  fi

  temp_file=$(mktemp)
  render_dynamic_routing_config_file "${temp_file}" "${dynamic_rules[@]}"

  if ! xray api adrules --server="${XRAY_API_SERVER}" -append "${temp_file}"; then
    rm -f "${temp_file}"
    docker_gateway_error "Failed to sync routing rules through Xray API."
    return 1
  fi

  current_rule_tags=("default-outbound")
  for rule_json in "${dynamic_rules[@]}"; do
    current_rule_tags+=("$(jq -r '.ruleTag' <<<"${rule_json}")")
  done
  printf '%s\n' "${current_rule_tags[@]}" > "${XRAY_DYNAMIC_RULE_TAGS_FILE}"

  rm -f "${temp_file}"
}

connect_container_to_network() {
  local container_id=$1
  local attach_network=$2
  local container_name=$3

  docker_gateway_log "Connecting ${container_name} (${container_id:0:12}) to network '${attach_network}'."
  if docker network connect "${attach_network}" "${container_id}" >/dev/null 2>&1; then
    return 0
  fi

  sleep 1
  if docker inspect "${container_id}" | jq -e --arg network "${attach_network}" '.[0].NetworkSettings.Networks[$network]' >/dev/null; then
    return 0
  fi

  docker_gateway_warn "Failed to connect ${container_name} (${container_id:0:12}) to network '${attach_network}'."
  return 1
}

apply_gateway_route() {
  local container_id=$1
  local container_name=$2
  local container_ip=$3
  local gateway_ip=$4
  local pid=$5
  local interface_name

  interface_name=$(nsenter -t "${pid}" -n ip -o -4 addr show | awk -v ip="${container_ip}" '$4 ~ ("^" ip "/") { print $2; exit }')
  if [ -z "${interface_name}" ]; then
    docker_gateway_warn "Unable to find interface for ${container_name} (${container_id:0:12}) IP ${container_ip}."
    return 1
  fi

  if ! nsenter -t "${pid}" -n ip route replace default via "${gateway_ip}" dev "${interface_name}"; then
    docker_gateway_warn "Unable to update default route for ${container_name} (${container_id:0:12})."
    return 1
  fi

  docker_gateway_log "Default route updated for ${container_name} (${container_id:0:12}) via ${gateway_ip} dev ${interface_name}."
}

manage_container() {
  local container_id=$1
  local attach_network=$2
  local gateway_ip=$3
  local inspect_json container_name network_mode pid container_ip outbound_tag

  inspect_json=$(docker inspect "${container_id}" 2>/dev/null) || return 0
  container_name=$(jq -r '.[0].Name | ltrimstr("/")' <<<"${inspect_json}")
  network_mode=$(jq -r '.[0].HostConfig.NetworkMode // empty' <<<"${inspect_json}")

  case "${network_mode}" in
    host|none|container:*)
      docker_gateway_warn "Skipping ${container_name} (${container_id:0:12}) because network mode '${network_mode}' is not supported."
      return 0
      ;;
  esac

  if ! jq -e --arg network "${attach_network}" '.[0].NetworkSettings.Networks[$network]' <<<"${inspect_json}" >/dev/null; then
    if ! connect_container_to_network "${container_id}" "${attach_network}" "${container_name}"; then
      return 0
    fi
    inspect_json=$(docker inspect "${container_id}" 2>/dev/null) || return 0
  fi

  container_ip=$(jq -r --arg network "${attach_network}" '.[0].NetworkSettings.Networks[$network].IPAddress // empty' <<<"${inspect_json}")
  pid=$(jq -r '.[0].State.Pid // 0' <<<"${inspect_json}")

  if [ -z "${container_ip}" ]; then
    docker_gateway_warn "Skipping ${container_name} (${container_id:0:12}) because it has no IP on network '${attach_network}'."
    return 0
  fi

  if [ "${pid}" -le 0 ]; then
    docker_gateway_warn "Skipping ${container_name} (${container_id:0:12}) because it has no running PID."
    return 0
  fi

  apply_gateway_route "${container_id}" "${container_name}" "${container_ip}" "${gateway_ip}" "${pid}" || return 0

  outbound_tag=$(jq -r --arg label "${DOCKER_GATEWAY_OUTBOUND_LABEL}" '.[0].Config.Labels[$label] // empty' <<<"${inspect_json}")
  if [ -z "${outbound_tag}" ]; then
    return 0
  fi

  if ! xray_outbound_exists "${outbound_tag}"; then
    docker_gateway_warn "Skipping outbound sync for ${container_name} (${container_id:0:12}) because tag '${outbound_tag}' does not exist."
    return 0
  fi

  build_dynamic_rule_json "${container_id}" "${container_ip}" "${outbound_tag}"
}

sync_gateway_state() {
  local context_json self_container_id gateway_name attach_network gateway_ip
  local -a container_ids dynamic_rules
  local container_id inspect_json target_gateway rule_json

  context_json=$(docker_gateway_resolve_context) || return 0
  self_container_id=$(jq -r '.container_id' <<<"${context_json}")
  gateway_name=$(jq -r '.gateway_name' <<<"${context_json}")
  attach_network=$(jq -r '.attach_network' <<<"${context_json}")
  gateway_ip=$(jq -r '.gateway_ip' <<<"${context_json}")

  if ! docker_gateway_validate_unique_name "${gateway_name}" "${self_container_id}"; then
    docker_gateway_warn "Skipping sync until gateway names are unique."
    return 0
  fi

  mapfile -t container_ids < <(docker ps -q --no-trunc | sort)
  for container_id in "${container_ids[@]}"; do
    [ -n "${container_id}" ] || continue
    [ "${container_id}" != "${self_container_id}" ] || continue

    inspect_json=$(docker inspect "${container_id}" 2>/dev/null) || continue
    target_gateway=$(jq -r --arg label "${DOCKER_GATEWAY_TARGET_LABEL}" '.[0].Config.Labels[$label] // empty' <<<"${inspect_json}")
    [ "${target_gateway}" = "${gateway_name}" ] || continue

    rule_json=$(manage_container "${container_id}" "${attach_network}" "${gateway_ip}") || true
    if [ -n "${rule_json}" ]; then
      dynamic_rules+=("${rule_json}")
    fi
  done

  sync_xray_routing "${dynamic_rules[@]}"
}

listen_for_events() {
  while true; do
    if ! docker events \
      --filter 'event=start' \
      --filter 'event=restart' \
      --filter 'event=stop' \
      --filter 'event=die' \
      --filter 'event=destroy' \
      --filter 'event=connect' \
      --filter 'event=disconnect' \
      --format '{{.Type}} {{.Action}} {{.Actor.ID}}' | while read -r event_type event_action event_id; do
        [ -n "${event_type}" ] || continue
        docker_gateway_log "Observed docker event: ${event_type} ${event_action} ${event_id:0:12}"
        sleep 1
        sync_gateway_state || true
      done; then
      docker_gateway_warn "Docker event stream returned an error."
    fi

    docker_gateway_warn "Docker event stream ended. Reconnecting in 1 second."
    sleep 1
  done
}

docker_gateway_require_socket
mkdir -p "${GATEWAY_STATE_DIR}"
printf '%s\n' "default-outbound" > "${XRAY_DYNAMIC_RULE_TAGS_FILE}"
wait_for_xray_api
sync_gateway_state || true
docker_gateway_log "Listening for docker events."
listen_for_events
