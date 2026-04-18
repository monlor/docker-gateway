#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
source "${SCRIPT_DIR}/gateway-common.sh"

XRAY_CONFIG_DIR=${XRAY_CONFIG_DIR:-/etc/xray}
XRAY_DEFAULT_RULE_PATH="${XRAY_CONFIG_DIR}/default-routing-rule.json"
XRAY_API_SERVER=${XRAY_API_SERVER:-127.0.0.1:${XRAY_API_PORT:-10085}}
GATEWAY_STATE_DIR=${GATEWAY_STATE_DIR:-/run/docker-gateway}
XRAY_DYNAMIC_RULE_TAGS_FILE="${GATEWAY_STATE_DIR}/dynamic-rule-tags"
XRAY_DYNAMIC_OUTBOUND_TAGS_FILE="${GATEWAY_STATE_DIR}/dynamic-outbound-tags"
XRAY_LAST_APPLIED_STATE_FILE="${GATEWAY_STATE_DIR}/applied-state.json"
XRAY_LAST_SYNC_REPORT_FILE="${GATEWAY_STATE_DIR}/last-sync-report.json"
XRAY_DEFAULT_RULE_TAG=${XRAY_DEFAULT_RULE_TAG:-default-outbound}
XRAY_DNS_CHAIN_NAME=${XRAY_DNS_CHAIN_NAME:-DOCKER_GATEWAY_DNS}
RULE_DOMAIN_JSON=$(jq -nc --arg domains "${RULE_DOMAIN:-}" 'if $domains == "" then [] else ($domains | split(",") | map(select(length > 0))) end')
AUTO_ATTACH_CONTAINERS=${AUTO_ATTACH_CONTAINERS:-false}
IPTABLES=""

json_array_from_values() {
  if [ "$#" -eq 0 ]; then
    printf '[]\n'
    return 0
  fi

  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

array_contains() {
  local needle=$1
  shift || true
  local item

  for item in "$@"; do
    if [ "${item}" = "${needle}" ]; then
      return 0
    fi
  done

  return 1
}

now_json_timestamp() {
  date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'
}

wait_for_xray_api() {
  local host port attempt

  host=${XRAY_API_SERVER%:*}
  port=${XRAY_API_SERVER##*:}

  for attempt in $(seq 1 30); do
    if docker_gateway_tcp_probe "${host}" "${port}"; then
      return 0
    fi

    docker_gateway_log "Waiting for Xray API on ${XRAY_API_SERVER} (${attempt}/30)"
    sleep 1
  done

  docker_gateway_error "Timed out waiting for Xray API on ${XRAY_API_SERVER}."
  return 1
}

build_proxy_rule_json() {
  local container_id=$1
  local container_ip=$2
  local outbound_tag=$3

  jq -nc \
    --arg rule_tag "docker-gateway-${container_id:0:12}-proxy" \
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

build_dns_direct_rule_json() {
  local container_id=$1
  local container_ip=$2
  local dns_server=$3

  jq -nc \
    --arg rule_tag "docker-gateway-${container_id:0:12}-dns-direct" \
    --arg source_ip "${container_ip}/32" \
    --arg dns_server "${dns_server}" \
    '{
      ruleTag: $rule_tag,
      type: "field",
      source: [$source_ip],
      ip: [$dns_server],
      port: 53,
      network: "tcp,udp",
      outboundTag: "direct"
    }'
}

render_dynamic_routing_config_file() {
  local output_file=$1
  local dynamic_rules_json=$2

  jq -n \
    --argjson dynamic_rules "${dynamic_rules_json}" \
    --slurpfile default_rule "${XRAY_DEFAULT_RULE_PATH}" \
    '{
      routing: {
        rules: ($dynamic_rules + [$default_rule[0]])
      }
    }' > "${output_file}"
}

render_dynamic_outbounds_config_file() {
  local output_file=$1
  local outbounds_json=$2

  jq -n \
    --argjson outbounds "${outbounds_json}" \
    '{
      outbounds: $outbounds
    }' > "${output_file}"
}

render_container_state_json() {
  local container_id=$1
  local container_name=$2
  local target_gateway=$3
  local status=$4
  local network_mode=$5
  local attach_network=$6
  local container_ip=$7
  local pid=$8
  local proxy_spec=$9
  local outbound_tag=${10}
  local dns_server=${11}
  local dns_mode=${12}
  local effective_dns_mode=${13}
  local auto_attach_allowed=${14}
  local attached_to_gateway_network=${15}
  local auto_attach_attempted=${16}
  local route_applied=${17}
  local dns_redirect_applied=${18}
  local reasons_json=${19}
  local errors_json=${20}
  local rules_json=${21}
  local outbound_json=${22}

  jq -nc \
    --arg container_id "${container_id}" \
    --arg container_name "${container_name}" \
    --arg target_gateway "${target_gateway}" \
    --arg status "${status}" \
    --arg network_mode "${network_mode}" \
    --arg attach_network "${attach_network}" \
    --arg container_ip "${container_ip}" \
    --argjson pid "${pid:-0}" \
    --arg proxy_spec "${proxy_spec}" \
    --arg outbound_tag "${outbound_tag}" \
    --arg dns_server "${dns_server}" \
    --arg dns_mode "${dns_mode}" \
    --arg effective_dns_mode "${effective_dns_mode}" \
    --argjson auto_attach_allowed "${auto_attach_allowed}" \
    --argjson attached_to_gateway_network "${attached_to_gateway_network}" \
    --argjson auto_attach_attempted "${auto_attach_attempted}" \
    --argjson route_applied "${route_applied}" \
    --argjson dns_redirect_applied "${dns_redirect_applied}" \
    --argjson reasons "${reasons_json}" \
    --argjson errors "${errors_json}" \
    --argjson rules "${rules_json}" \
    --argjson outbound "${outbound_json}" \
    '{
      container_id: $container_id,
      container_name: $container_name,
      target_gateway: $target_gateway,
      status: $status,
      network_mode: $network_mode,
      attach_network: $attach_network,
      container_ip: (if $container_ip == "" then null else $container_ip end),
      pid: $pid,
      proxy_spec: (if $proxy_spec == "" then null else $proxy_spec end),
      outbound_tag: (if $outbound_tag == "" then null else $outbound_tag end),
      dns_server: (if $dns_server == "" then null else $dns_server end),
      dns_mode: (if $dns_mode == "" then null else $dns_mode end),
      effective_dns_mode: (if $effective_dns_mode == "" then null else $effective_dns_mode end),
      auto_attach_allowed: $auto_attach_allowed,
      attached_to_gateway_network: $attached_to_gateway_network,
      auto_attach_attempted: $auto_attach_attempted,
      route_applied: $route_applied,
      dns_redirect_applied: $dns_redirect_applied,
      reasons: $reasons,
      errors: $errors,
      rules: $rules,
      outbound: $outbound
    }'
}

write_json_file() {
  local path=$1
  local json=$2
  local temp_file

  temp_file=$(mktemp)
  printf '%s\n' "${json}" > "${temp_file}"
  mv "${temp_file}" "${path}"
}

read_previous_applied_state_json() {
  if [ -s "${XRAY_LAST_APPLIED_STATE_FILE}" ]; then
    cat "${XRAY_LAST_APPLIED_STATE_FILE}"
  else
    printf '{"gateway":null,"containers":[],"desired_rules":[],"desired_outbounds":[]}\n'
  fi
}

write_sync_report() {
  local status=$1
  local state_json=$2
  local error_message=${3:-}
  local report_json

  report_json=$(jq -nc \
    --arg status "${status}" \
    --arg generated_at "$(now_json_timestamp)" \
    --arg error "${error_message}" \
    --argjson state "${state_json}" \
    '{
      status: $status,
      generated_at: $generated_at,
      error: (if $error == "" then null else $error end),
      state: $state
    }')

  write_json_file "${XRAY_LAST_SYNC_REPORT_FILE}" "${report_json}"
}

persist_rule_tags() {
  local rules_json=$1
  local rule_tags_json

  rule_tags_json=$(jq -nc \
    --arg default_tag "${XRAY_DEFAULT_RULE_TAG}" \
    --argjson rules "${rules_json}" \
    '[$default_tag] + ($rules | map(.ruleTag))')

  jq -r '.[]' <<<"${rule_tags_json}" > "${XRAY_DYNAMIC_RULE_TAGS_FILE}"
}

persist_outbound_tags() {
  local outbounds_json=$1

  jq -r '.[].tag' <<<"${outbounds_json}" > "${XRAY_DYNAMIC_OUTBOUND_TAGS_FILE}"
}

read_current_rule_tags() {
  local previous_state_json=$1

  if [ -s "${XRAY_DYNAMIC_RULE_TAGS_FILE}" ]; then
    cat "${XRAY_DYNAMIC_RULE_TAGS_FILE}"
    return 0
  fi

  jq -r \
    --arg default_tag "${XRAY_DEFAULT_RULE_TAG}" \
    '.desired_rules // [] | [$default_tag] + (map(.ruleTag)) | .[]' \
    <<<"${previous_state_json}"
}

read_current_outbound_tags() {
  local previous_state_json=$1

  if [ -s "${XRAY_DYNAMIC_OUTBOUND_TAGS_FILE}" ]; then
    cat "${XRAY_DYNAMIC_OUTBOUND_TAGS_FILE}"
    return 0
  fi

  jq -r '.desired_outbounds // [] | map(.tag) | .[]' <<<"${previous_state_json}"
}

xray_add_rules_from_json() {
  local rules_json=$1
  local temp_file

  temp_file=$(mktemp)
  render_dynamic_routing_config_file "${temp_file}" "${rules_json}"

  if xray api adrules --server="${XRAY_API_SERVER}" -append "${temp_file}" >/dev/null 2>&1; then
    rm -f "${temp_file}"
    return 0
  fi

  rm -f "${temp_file}"
  return 1
}

xray_add_outbounds_from_json() {
  local outbounds_json=$1
  local temp_file

  temp_file=$(mktemp)
  render_dynamic_outbounds_config_file "${temp_file}" "${outbounds_json}"

  if xray api ado --server="${XRAY_API_SERVER}" "${temp_file}" >/dev/null 2>&1; then
    rm -f "${temp_file}"
    return 0
  fi

  rm -f "${temp_file}"
  return 1
}

xray_remove_rules_by_tags() {
  local -a rule_tags=("$@")
  local rule_tag

  if [ "${#rule_tags[@]}" -eq 0 ]; then
    return 0
  fi

  if xray api rmrules --server="${XRAY_API_SERVER}" "${rule_tags[@]}" >/dev/null 2>&1; then
    return 0
  fi

  docker_gateway_warn "Bulk dynamic rule removal failed. Falling back to per-tag cleanup."
  for rule_tag in "${rule_tags[@]}"; do
    [ -n "${rule_tag}" ] || continue
    if ! xray api rmrules --server="${XRAY_API_SERVER}" "${rule_tag}" >/dev/null 2>&1; then
      docker_gateway_warn "Unable to remove dynamic rule tag '${rule_tag}'. Continuing."
    fi
  done
}

xray_remove_outbounds_by_tags() {
  local -a outbound_tags=("$@")
  local outbound_tag

  if [ "${#outbound_tags[@]}" -eq 0 ]; then
    return 0
  fi

  if xray api rmo --server="${XRAY_API_SERVER}" "${outbound_tags[@]}" >/dev/null 2>&1; then
    return 0
  fi

  docker_gateway_warn "Bulk dynamic outbound removal failed. Falling back to per-tag cleanup."
  for outbound_tag in "${outbound_tags[@]}"; do
    [ -n "${outbound_tag}" ] || continue
    if ! xray api rmo --server="${XRAY_API_SERVER}" "${outbound_tag}" >/dev/null 2>&1; then
      docker_gateway_warn "Unable to remove dynamic outbound tag '${outbound_tag}'. Continuing."
    fi
  done
}

sync_xray_routing() {
  local desired_rules_json=$1
  local previous_state_json=$2
  local previous_rules_json desired_rule_tags_json
  local -a current_rule_tags=() removable_rule_tags=() desired_rule_tags=()
  local rule_tag

  previous_rules_json=$(jq -c '.desired_rules // []' <<<"${previous_state_json}")
  mapfile -t current_rule_tags < <(read_current_rule_tags "${previous_state_json}")
  for rule_tag in "${current_rule_tags[@]}"; do
    [ -n "${rule_tag}" ] || continue
    if [ "${rule_tag}" != "${XRAY_DEFAULT_RULE_TAG}" ]; then
      removable_rule_tags+=("${rule_tag}")
    fi
  done

  xray_remove_rules_by_tags "${removable_rule_tags[@]}"

  if xray_add_rules_from_json "${desired_rules_json}"; then
    persist_rule_tags "${desired_rules_json}"
    return 0
  fi

  docker_gateway_warn "Initial dynamic rule add failed. Retrying after clearing desired rule tags."
  desired_rule_tags_json=$(jq -nc --argjson rules "${desired_rules_json}" '$rules | map(.ruleTag)')
  mapfile -t desired_rule_tags < <(jq -r '.[]' <<<"${desired_rule_tags_json}")
  xray_remove_rules_by_tags "${desired_rule_tags[@]}"

  if xray_add_rules_from_json "${desired_rules_json}"; then
    persist_rule_tags "${desired_rules_json}"
    return 0
  fi

  docker_gateway_error "Failed to sync dynamic routing rules. Attempting rollback."
  if xray_add_rules_from_json "${previous_rules_json}"; then
    persist_rule_tags "${previous_rules_json}"
  else
    printf '%s\n' "${XRAY_DEFAULT_RULE_TAG}" > "${XRAY_DYNAMIC_RULE_TAGS_FILE}"
  fi

  return 1
}

sync_xray_outbounds() {
  local desired_outbounds_json=$1
  local previous_state_json=$2
  local previous_outbounds_json outbound_json outbound_tag
  local -a previous_outbound_tags=() desired_outbound_tags=() outbounds_to_add=() stale_outbound_tags=()

  previous_outbounds_json=$(jq -c '.desired_outbounds // []' <<<"${previous_state_json}")

  while IFS= read -r outbound_tag; do
    [ -n "${outbound_tag}" ] || continue
    previous_outbound_tags+=("${outbound_tag}")
  done < <(read_current_outbound_tags "${previous_state_json}")

  while IFS= read -r outbound_json; do
    [ -n "${outbound_json}" ] || continue
    outbound_tag=$(jq -r '.tag' <<<"${outbound_json}")
    desired_outbound_tags+=("${outbound_tag}")
    if ! array_contains "${outbound_tag}" "${previous_outbound_tags[@]}"; then
      outbounds_to_add+=("${outbound_json}")
    fi
  done < <(jq -c '.[]' <<<"${desired_outbounds_json}")

  for outbound_tag in "${previous_outbound_tags[@]}"; do
    if ! array_contains "${outbound_tag}" "${desired_outbound_tags[@]}"; then
      stale_outbound_tags+=("${outbound_tag}")
    fi
  done

  if [ "${#outbounds_to_add[@]}" -gt 0 ]; then
    if ! xray_add_outbounds_from_json "$(printf '%s\n' "${outbounds_to_add[@]}" | jq -s '.')"; then
      docker_gateway_warn "Initial dynamic outbound add failed. Retrying after clearing desired outbound tags."
      xray_remove_outbounds_by_tags "${desired_outbound_tags[@]}"
      if ! xray_add_outbounds_from_json "${desired_outbounds_json}"; then
        docker_gateway_error "Failed to sync dynamic outbounds."
        if [ "$(jq 'length' <<<"${previous_outbounds_json}")" -gt 0 ]; then
          xray_add_outbounds_from_json "${previous_outbounds_json}" || true
          persist_outbound_tags "${previous_outbounds_json}"
        else
          : > "${XRAY_DYNAMIC_OUTBOUND_TAGS_FILE}"
        fi
        return 1
      fi
    fi
  fi

  persist_outbound_tags "${desired_outbounds_json}"

  if [ "${#stale_outbound_tags[@]}" -gt 0 ]; then
    xray_remove_outbounds_by_tags "${stale_outbound_tags[@]}"
  fi

  return 0
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

clear_container_dns_redirect() {
  local pid=$1

  while nsenter -t "${pid}" -n "${IPTABLES}" -t nat -D OUTPUT -p udp --dport 53 -j "${XRAY_DNS_CHAIN_NAME}" >/dev/null 2>&1; do :; done
  while nsenter -t "${pid}" -n "${IPTABLES}" -t nat -D OUTPUT -p tcp --dport 53 -j "${XRAY_DNS_CHAIN_NAME}" >/dev/null 2>&1; do :; done

  if nsenter -t "${pid}" -n "${IPTABLES}" -t nat -S "${XRAY_DNS_CHAIN_NAME}" >/dev/null 2>&1; then
    nsenter -t "${pid}" -n "${IPTABLES}" -t nat -F "${XRAY_DNS_CHAIN_NAME}" >/dev/null 2>&1 || true
    nsenter -t "${pid}" -n "${IPTABLES}" -t nat -X "${XRAY_DNS_CHAIN_NAME}" >/dev/null 2>&1 || true
  fi
}

apply_container_dns_redirect() {
  local pid=$1
  local dns_server=$2

  if ! clear_container_dns_redirect "${pid}"; then
    docker_gateway_warn "Unable to clear existing DNS redirect for PID ${pid}."
    return 1
  fi

  if ! nsenter -t "${pid}" -n "${IPTABLES}" -t nat -N "${XRAY_DNS_CHAIN_NAME}" >/dev/null 2>&1; then
    if ! nsenter -t "${pid}" -n "${IPTABLES}" -t nat -S "${XRAY_DNS_CHAIN_NAME}" >/dev/null 2>&1; then
      docker_gateway_warn "Unable to create DNS redirect chain '${XRAY_DNS_CHAIN_NAME}' for PID ${pid}."
      return 1
    fi
  fi

  if ! nsenter -t "${pid}" -n "${IPTABLES}" -t nat -F "${XRAY_DNS_CHAIN_NAME}" >/dev/null 2>&1; then
    docker_gateway_warn "Unable to flush DNS redirect chain '${XRAY_DNS_CHAIN_NAME}' for PID ${pid}."
    return 1
  fi

  if ! nsenter -t "${pid}" -n "${IPTABLES}" -t nat -A "${XRAY_DNS_CHAIN_NAME}" -p udp --dport 53 -j DNAT --to-destination "${dns_server}:53" >/dev/null 2>&1; then
    docker_gateway_warn "Unable to install UDP DNS redirect for PID ${pid}."
    return 1
  fi

  if ! nsenter -t "${pid}" -n "${IPTABLES}" -t nat -A "${XRAY_DNS_CHAIN_NAME}" -p tcp --dport 53 -j DNAT --to-destination "${dns_server}:53" >/dev/null 2>&1; then
    docker_gateway_warn "Unable to install TCP DNS redirect for PID ${pid}."
    return 1
  fi

  if ! nsenter -t "${pid}" -n "${IPTABLES}" -t nat -C OUTPUT -p udp --dport 53 -j "${XRAY_DNS_CHAIN_NAME}" >/dev/null 2>&1; then
    if ! nsenter -t "${pid}" -n "${IPTABLES}" -t nat -A OUTPUT -p udp --dport 53 -j "${XRAY_DNS_CHAIN_NAME}" >/dev/null 2>&1; then
      docker_gateway_warn "Unable to hook UDP DNS redirect chain into OUTPUT for PID ${pid}."
      return 1
    fi
  fi

  if ! nsenter -t "${pid}" -n "${IPTABLES}" -t nat -C OUTPUT -p tcp --dport 53 -j "${XRAY_DNS_CHAIN_NAME}" >/dev/null 2>&1; then
    if ! nsenter -t "${pid}" -n "${IPTABLES}" -t nat -A OUTPUT -p tcp --dport 53 -j "${XRAY_DNS_CHAIN_NAME}" >/dev/null 2>&1; then
      docker_gateway_warn "Unable to hook TCP DNS redirect chain into OUTPUT for PID ${pid}."
      return 1
    fi
  fi

  return 0
}

should_auto_attach_container() {
  local allow_attach_label=$1

  if docker_gateway_bool_is_true "${allow_attach_label}"; then
    return 0
  fi

  docker_gateway_bool_is_true "${AUTO_ATTACH_CONTAINERS}"
}

manage_container() {
  local container_id=$1
  local attach_network=$2
  local gateway_ip=$3
  local apply_mode=${4:-apply}
  local inspect_json labels_json container_name target_gateway network_mode
  local proxy_spec dns_server dns_mode allow_attach_label effective_dns_mode=""
  local proxy_payload_json outbound_json='null' outbound_tag=""
  local container_ip="" pid=0 status="managed"
  local auto_attach_allowed=false attached_to_gateway_network=false auto_attach_attempted=false
  local route_applied=false dns_redirect_applied=false strict_labels=false
  local reasons_json errors_json rules_json
  local -a dynamic_rules=() reasons=() errors=()

  inspect_json=$(docker inspect "${container_id}" 2>/dev/null) || {
    reasons+=("container inspection failed")
    status="skipped"
    render_container_state_json \
      "${container_id}" "" "" "${status}" "" "${attach_network}" "" "0" "" "" "" "" "" \
      false false false false false \
      "$(json_array_from_values "${reasons[@]}")" "$(json_array_from_values "${errors[@]}")" '[]' 'null'
    return 0
  }

  labels_json=$(docker_gateway_container_labels_json "${inspect_json}")
  container_name=$(jq -r '.container_name' <<<"${labels_json}")
  target_gateway=$(jq -r '.target_gateway' <<<"${labels_json}")
  network_mode=$(jq -r '.network_mode' <<<"${labels_json}")
  proxy_spec=$(jq -r '.proxy_spec' <<<"${labels_json}")
  dns_server=$(jq -r '.dns_server' <<<"${labels_json}")
  dns_mode=$(jq -r '.dns_mode' <<<"${labels_json}")
  allow_attach_label=$(jq -r '.allow_attach' <<<"${labels_json}")

  if docker_gateway_strict_labels_enabled; then
    strict_labels=true
  fi

  case "${network_mode}" in
    host|none|container:*)
      status="skipped"
      reasons+=("unsupported network mode '${network_mode}'")
      render_container_state_json \
        "${container_id}" "${container_name}" "${target_gateway}" "${status}" "${network_mode}" "${attach_network}" "" "0" \
        "${proxy_spec}" "" "${dns_server}" "${dns_mode}" "" \
        false false false false false \
        "$(json_array_from_values "${reasons[@]}")" "$(json_array_from_values "${errors[@]}")" '[]' 'null'
      return 0
      ;;
  esac

  if jq -e --arg network "${attach_network}" '.[0].NetworkSettings.Networks[$network]' <<<"${inspect_json}" >/dev/null; then
    attached_to_gateway_network=true
  else
    if should_auto_attach_container "${allow_attach_label}"; then
      auto_attach_allowed=true
      reasons+=("container is not attached to '${attach_network}'")
      if [ "${apply_mode}" = "apply" ]; then
        auto_attach_attempted=true
        if ! connect_container_to_network "${container_id}" "${attach_network}" "${container_name}"; then
          status="error"
          errors+=("failed to connect container to '${attach_network}'")
        else
          inspect_json=$(docker inspect "${container_id}" 2>/dev/null) || inspect_json=""
          if [ -n "${inspect_json}" ] && jq -e --arg network "${attach_network}" '.[0].NetworkSettings.Networks[$network]' <<<"${inspect_json}" >/dev/null; then
            attached_to_gateway_network=true
          fi
        fi
      else
        status="planned"
        reasons+=("would connect container to '${attach_network}'")
      fi
    else
      status="skipped"
      reasons+=("container is not attached to '${attach_network}' and auto attach is disabled")
    fi
  fi

  if [ "${status}" = "error" ] || [ "${status}" = "skipped" ] || { [ "${status}" = "planned" ] && [ "${attached_to_gateway_network}" != true ]; }; then
    render_container_state_json \
      "${container_id}" "${container_name}" "${target_gateway}" "${status}" "${network_mode}" "${attach_network}" "" "0" \
      "${proxy_spec}" "" "${dns_server}" "${dns_mode}" "" \
      "${auto_attach_allowed}" "${attached_to_gateway_network}" "${auto_attach_attempted}" false false \
      "$(json_array_from_values "${reasons[@]}")" "$(json_array_from_values "${errors[@]}")" '[]' 'null'
    return 0
  fi

  container_ip=$(jq -r --arg network "${attach_network}" '.[0].NetworkSettings.Networks[$network].IPAddress // empty' <<<"${inspect_json}")
  pid=$(jq -r '.[0].State.Pid // 0' <<<"${inspect_json}")

  if [ -z "${container_ip}" ]; then
    status="skipped"
    reasons+=("container has no IP on '${attach_network}'")
  fi

  if [ "${pid}" -le 0 ]; then
    status="skipped"
    reasons+=("container is not running")
  fi

  if [ "${status}" = "skipped" ]; then
    render_container_state_json \
      "${container_id}" "${container_name}" "${target_gateway}" "${status}" "${network_mode}" "${attach_network}" "${container_ip}" "${pid}" \
      "${proxy_spec}" "" "${dns_server}" "${dns_mode}" "" \
      "${auto_attach_allowed}" "${attached_to_gateway_network}" "${auto_attach_attempted}" false false \
      "$(json_array_from_values "${reasons[@]}")" "$(json_array_from_values "${errors[@]}")" '[]' 'null'
    return 0
  fi

  if [ "${apply_mode}" = "apply" ]; then
    if apply_gateway_route "${container_id}" "${container_name}" "${container_ip}" "${gateway_ip}" "${pid}"; then
      route_applied=true
    else
      status="error"
      errors+=("failed to update default route")
    fi
  else
    route_applied=true
    reasons+=("would update default route via '${gateway_ip}'")
  fi

  if [ "${status}" = "error" ]; then
    render_container_state_json \
      "${container_id}" "${container_name}" "${target_gateway}" "${status}" "${network_mode}" "${attach_network}" "${container_ip}" "${pid}" \
      "${proxy_spec}" "" "${dns_server}" "${dns_mode}" "" \
      "${auto_attach_allowed}" "${attached_to_gateway_network}" "${auto_attach_attempted}" "${route_applied}" false \
      "$(json_array_from_values "${reasons[@]}")" "$(json_array_from_values "${errors[@]}")" '[]' 'null'
    return 0
  fi

  if [ -n "${proxy_spec}" ]; then
    if proxy_payload_json=$(docker_gateway_build_proxy_payload_json "${proxy_spec}"); then
      if outbound_tag=$(docker_gateway_proxy_tag_from_payload "${proxy_payload_json}"); then
        outbound_json=$(docker_gateway_build_outbound_json "${outbound_tag}" "${proxy_payload_json}")
      else
        status="error"
        errors+=("failed to build a stable outbound tag for proxy '${proxy_spec}'")
      fi
    else
      if [ "${strict_labels}" = true ]; then
        status="error"
        errors+=("invalid proxy label '${proxy_spec}'")
      else
        reasons+=("invalid proxy label was ignored")
        docker_gateway_warn "Skipping proxy routing for ${container_name} (${container_id:0:12}) due to invalid proxy label."
      fi
    fi
  fi

  if [ -n "${dns_server}" ]; then
    if ! docker_gateway_is_ipv4 "${dns_server}"; then
      if [ "${strict_labels}" = true ]; then
        status="error"
        errors+=("dns server '${dns_server}' is not a single IPv4 address")
      else
        reasons+=("invalid dns server '${dns_server}' was ignored")
        docker_gateway_warn "Skipping DNS override for ${container_name} (${container_id:0:12}) because '${dns_server}' is not a single IPv4 address."
        dns_server=""
      fi
    fi
  fi

  if [ -n "${dns_server}" ]; then
    case "${dns_mode:-direct}" in
      direct|proxy)
        effective_dns_mode=${dns_mode:-direct}
        ;;
      "")
        effective_dns_mode=direct
        ;;
      *)
        if [ "${strict_labels}" = true ]; then
          status="error"
          errors+=("invalid dns mode '${dns_mode}'")
        else
          reasons+=("invalid dns mode '${dns_mode}' fell back to 'direct'")
          docker_gateway_warn "Invalid DNS mode '${dns_mode}' for ${container_name} (${container_id:0:12}); falling back to 'direct'."
          effective_dns_mode=direct
        fi
        ;;
    esac

    if [ "${effective_dns_mode}" = "proxy" ] && [ -z "${outbound_tag}" ]; then
      if [ "${strict_labels}" = true ]; then
        status="error"
        errors+=("dns-mode=proxy requires a valid proxy label")
      else
        reasons+=("dns-mode=proxy fell back to 'direct' because no valid proxy label was present")
        docker_gateway_warn "DNS mode 'proxy' requires a valid proxy label for ${container_name} (${container_id:0:12}); falling back to 'direct'."
        effective_dns_mode=direct
      fi
    fi
  fi

  if [ "${status}" != "error" ] && [ -n "${dns_server}" ]; then
    if [ "${apply_mode}" = "apply" ]; then
      if apply_container_dns_redirect "${pid}" "${dns_server}"; then
        dns_redirect_applied=true
        docker_gateway_log "DNS redirect updated for ${container_name} (${container_id:0:12}) to ${dns_server} (${effective_dns_mode})."
      else
        reasons+=("dns redirect update failed and was skipped")
        docker_gateway_warn "Skipping DNS override for ${container_name} (${container_id:0:12}) because DNS redirect setup failed."
      fi
    else
      dns_redirect_applied=true
      reasons+=("would redirect DNS to '${dns_server}' (${effective_dns_mode})")
    fi

    if [ "${dns_redirect_applied}" = true ] && [ "${effective_dns_mode}" = "direct" ]; then
      dynamic_rules+=("$(build_dns_direct_rule_json "${container_id}" "${container_ip}" "${dns_server}")")
    fi
  elif [ "${status}" != "error" ] && [ "${apply_mode}" = "apply" ]; then
    clear_container_dns_redirect "${pid}" || true
  fi

  if [ -n "${outbound_tag}" ]; then
    dynamic_rules+=("$(build_proxy_rule_json "${container_id}" "${container_ip}" "${outbound_tag}")")
  fi

  rules_json=$(printf '%s\n' "${dynamic_rules[@]}" | jq -s '.')
  reasons_json=$(json_array_from_values "${reasons[@]}")
  errors_json=$(json_array_from_values "${errors[@]}")

  render_container_state_json \
    "${container_id}" "${container_name}" "${target_gateway}" "${status}" "${network_mode}" "${attach_network}" "${container_ip}" "${pid}" \
    "${proxy_spec}" "${outbound_tag}" "${dns_server}" "${dns_mode}" "${effective_dns_mode}" \
    "${auto_attach_allowed}" "${attached_to_gateway_network}" "${auto_attach_attempted}" "${route_applied}" "${dns_redirect_applied}" \
    "${reasons_json}" "${errors_json}" "${rules_json}" "${outbound_json}"
}

build_gateway_state_json() {
  local apply_mode=${1:-apply}
  local context_json self_container_id gateway_name attach_network gateway_ip
  local container_id inspect_json target_gateway container_state container_status
  local desired_rules_json desired_outbounds_json containers_json strict_failure=false
  local -a container_ids=() container_states=() desired_rule_entries=() desired_outbound_entries=()

  context_json=$(docker_gateway_resolve_context) || return 1
  self_container_id=$(jq -r '.container_id' <<<"${context_json}")
  gateway_name=$(jq -r '.gateway_name' <<<"${context_json}")
  attach_network=$(jq -r '.attach_network' <<<"${context_json}")
  gateway_ip=$(jq -r '.gateway_ip' <<<"${context_json}")

  if ! docker_gateway_validate_unique_name "${gateway_name}" "${self_container_id}"; then
    docker_gateway_warn "Skipping sync until gateway names are unique."
  fi

  mapfile -t container_ids < <(docker ps -q --no-trunc | sort)
  for container_id in "${container_ids[@]}"; do
    [ -n "${container_id}" ] || continue
    [ "${container_id}" != "${self_container_id}" ] || continue

    inspect_json=$(docker inspect "${container_id}" 2>/dev/null) || continue
    target_gateway=$(docker_gateway_label_value "${inspect_json}" "${DOCKER_GATEWAY_TARGET_LABEL}")
    [ "${target_gateway}" = "${gateway_name}" ] || continue

    container_state=$(manage_container "${container_id}" "${attach_network}" "${gateway_ip}" "${apply_mode}") || continue
    container_states+=("${container_state}")

    while IFS= read -r rule_json; do
      [ -n "${rule_json}" ] || continue
      desired_rule_entries+=("${rule_json}")
    done < <(jq -c '.rules[]?' <<<"${container_state}")

    while IFS= read -r outbound_json; do
      [ -n "${outbound_json}" ] || continue
      desired_outbound_entries+=("${outbound_json}")
    done < <(jq -c '.outbound | select(. != null)' <<<"${container_state}")

    container_status=$(jq -r '.status' <<<"${container_state}")
    if [ "${container_status}" = "error" ] && docker_gateway_strict_labels_enabled; then
      strict_failure=true
    fi
  done

  if [ "${#desired_rule_entries[@]}" -gt 0 ]; then
    desired_rules_json=$(printf '%s\n' "${desired_rule_entries[@]}" | jq -s '.')
  else
    desired_rules_json='[]'
  fi

  if [ "${#desired_outbound_entries[@]}" -gt 0 ]; then
    desired_outbounds_json=$(printf '%s\n' "${desired_outbound_entries[@]}" | jq -s 'group_by(.tag) | map(.[-1]) | sort_by(.tag)')
  else
    desired_outbounds_json='[]'
  fi

  if [ "${#container_states[@]}" -gt 0 ]; then
    containers_json=$(printf '%s\n' "${container_states[@]}" | jq -s '.')
  else
    containers_json='[]'
  fi

  jq -nc \
    --arg generated_at "$(now_json_timestamp)" \
    --arg apply_mode "${apply_mode}" \
    --argjson gateway "${context_json}" \
    --argjson containers "${containers_json}" \
    --argjson desired_rules "${desired_rules_json}" \
    --argjson desired_outbounds "${desired_outbounds_json}" \
    --argjson strict_failure "${strict_failure}" \
    '{
      generated_at: $generated_at,
      apply_mode: $apply_mode,
      gateway: $gateway,
      strict_failure: $strict_failure,
      containers: $containers,
      desired_rules: $desired_rules,
      desired_outbounds: $desired_outbounds
    }'
}

sync_gateway_state() {
  local state_json previous_state_json desired_rules_json desired_outbounds_json

  state_json=$(build_gateway_state_json "apply") || return 1
  write_sync_report "planned" "${state_json}"

  if [ "$(jq -r '.strict_failure' <<<"${state_json}")" = "true" ]; then
    write_sync_report "failed" "${state_json}" "strict label validation failed"
    docker_gateway_error "Strict label validation failed. Refusing to apply a partial sync."
    return 1
  fi

  previous_state_json=$(read_previous_applied_state_json)
  desired_rules_json=$(jq -c '.desired_rules // []' <<<"${state_json}")
  desired_outbounds_json=$(jq -c '.desired_outbounds // []' <<<"${state_json}")

  if ! sync_xray_outbounds "${desired_outbounds_json}" "${previous_state_json}"; then
    write_sync_report "failed" "${state_json}" "dynamic outbound sync failed"
    return 1
  fi

  if ! sync_xray_routing "${desired_rules_json}" "${previous_state_json}"; then
    write_sync_report "failed" "${state_json}" "dynamic routing sync failed"
    return 1
  fi

  write_json_file "${XRAY_LAST_APPLIED_STATE_FILE}" "${state_json}"
  write_sync_report "applied" "${state_json}"
}

print_status() {
  if [ -s "${XRAY_LAST_SYNC_REPORT_FILE}" ]; then
    cat "${XRAY_LAST_SYNC_REPORT_FILE}"
    return 0
  fi

  if [ -s "${XRAY_LAST_APPLIED_STATE_FILE}" ]; then
    jq -nc \
      --arg status "applied" \
      --arg generated_at "$(now_json_timestamp)" \
      --argjson state "$(cat "${XRAY_LAST_APPLIED_STATE_FILE}")" \
      '{status: $status, generated_at: $generated_at, error: null, state: $state}'
    return 0
  fi

  jq -nc --arg status "unknown" --arg generated_at "$(now_json_timestamp)" '{status: $status, generated_at: $generated_at, error: "no sync state available", state: null}'
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

main() {
  local mode=${1:-daemon}

  case "${mode}" in
    --status)
      print_status
      ;;
    --print-desired-state)
      docker_gateway_require_socket
      mkdir -p "${GATEWAY_STATE_DIR}"
      touch "${XRAY_DYNAMIC_RULE_TAGS_FILE}" "${XRAY_DYNAMIC_OUTBOUND_TAGS_FILE}"
      build_gateway_state_json "dry-run"
      ;;
    --sync-once)
      docker_gateway_require_socket
      mkdir -p "${GATEWAY_STATE_DIR}"
      touch "${XRAY_DYNAMIC_RULE_TAGS_FILE}" "${XRAY_DYNAMIC_OUTBOUND_TAGS_FILE}"
      IPTABLES=$(docker_gateway_detect_iptables_command "${IPTABLES_COMMAND:-}") || {
        docker_gateway_error "Unable to find a working iptables binary. Set IPTABLES_COMMAND to a valid command."
        return 1
      }
      wait_for_xray_api
      sync_gateway_state
      print_status
      ;;
    ""|daemon)
      docker_gateway_require_socket
      mkdir -p "${GATEWAY_STATE_DIR}"
      touch "${XRAY_DYNAMIC_RULE_TAGS_FILE}" "${XRAY_DYNAMIC_OUTBOUND_TAGS_FILE}"
      IPTABLES=$(docker_gateway_detect_iptables_command "${IPTABLES_COMMAND:-}") || {
        docker_gateway_error "Unable to find a working iptables binary. Set IPTABLES_COMMAND to a valid command."
        return 1
      }
      wait_for_xray_api
      sync_gateway_state || true
      docker_gateway_log "Listening for docker events."
      listen_for_events
      ;;
    *)
      docker_gateway_error "Unknown mode '${mode}'. Use --sync-once, --print-desired-state, or --status."
      return 1
      ;;
  esac
}

main "$@"
