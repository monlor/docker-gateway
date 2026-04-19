#!/bin/bash

DOCKER_GATEWAY_NAME_LABEL=${DOCKER_GATEWAY_NAME_LABEL:-docker-gateway.name}
DOCKER_GATEWAY_ATTACH_NETWORK_LABEL=${DOCKER_GATEWAY_ATTACH_NETWORK_LABEL:-docker-gateway.attach-network}
DOCKER_GATEWAY_TARGET_LABEL=${DOCKER_GATEWAY_TARGET_LABEL:-docker-gateway.gateway}
DOCKER_GATEWAY_PROXY_LABEL=${DOCKER_GATEWAY_PROXY_LABEL:-docker-gateway.proxy}
DOCKER_GATEWAY_DNS_SERVERS_LABEL=${DOCKER_GATEWAY_DNS_SERVERS_LABEL:-docker-gateway.dns-servers}
DOCKER_GATEWAY_DNS_MODE_LABEL=${DOCKER_GATEWAY_DNS_MODE_LABEL:-docker-gateway.dns-mode}
DOCKER_GATEWAY_ALLOW_ATTACH_LABEL=${DOCKER_GATEWAY_ALLOW_ATTACH_LABEL:-docker-gateway.allow-attach}
DOCKER_GATEWAY_PROXY_SPEC_MAX_LENGTH=${DOCKER_GATEWAY_PROXY_SPEC_MAX_LENGTH:-512}
DOCKER_GATEWAY_PROXY_SERVER_MAX_COUNT=${DOCKER_GATEWAY_PROXY_SERVER_MAX_COUNT:-8}
DOCKER_GATEWAY_PROXY_FIELD_MAX_LENGTH=${DOCKER_GATEWAY_PROXY_FIELD_MAX_LENGTH:-255}

DOCKER_GATEWAY_RESOLVED_IPV4_CACHE=${DOCKER_GATEWAY_RESOLVED_IPV4_CACHE:-}

docker_gateway_normalized_log_level() {
  case "${LOG_LEVEL:-info}" in
    debug|info|warning|error|none)
      printf '%s\n' "${LOG_LEVEL:-info}"
      ;;
    warn)
      printf 'warning\n'
      ;;
    *)
      printf 'info\n'
      ;;
  esac
}

docker_gateway_should_log() {
  local message_level=$1
  local current_level

  current_level=$(docker_gateway_normalized_log_level)

  case "${current_level}" in
    debug)
      return 0
      ;;
    info)
      [ "${message_level}" != "debug" ]
      return $?
      ;;
    warning)
      [ "${message_level}" = "warning" ] || [ "${message_level}" = "error" ]
      return $?
      ;;
    error)
      [ "${message_level}" = "error" ]
      return $?
      ;;
    none)
      return 1
      ;;
  esac

  return 0
}

docker_gateway_log() {
  docker_gateway_should_log info || return 0
  printf '[docker-gateway] %s\n' "$*" >&2
}

docker_gateway_warn() {
  docker_gateway_should_log warning || return 0
  printf '[docker-gateway] WARN: %s\n' "$*" >&2
}

docker_gateway_error() {
  docker_gateway_should_log error || return 0
  printf '[docker-gateway] ERROR: %s\n' "$*" >&2
}

docker_gateway_require_socket() {
  if [ ! -S /var/run/docker.sock ]; then
    docker_gateway_error "Docker socket not found. Mount /var/run/docker.sock into the gateway container."
    return 1
  fi
}

docker_gateway_self_container_id() {
  hostname
}

docker_gateway_trim() {
  local value=$1

  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "${value}"
}

docker_gateway_bool_is_true() {
  local normalized_value

  normalized_value=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')

  case "${normalized_value}" in
    1|true|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

docker_gateway_strict_labels_enabled() {
  docker_gateway_bool_is_true "${STRICT_LABELS:-false}"
}

docker_gateway_command_exists() {
  command -v "$1" >/dev/null 2>&1
}

docker_gateway_cache_get() {
  local cache_blob=$1
  local cache_key=$2
  local line

  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    if [ "${line%%$'\t'*}" = "${cache_key}" ]; then
      printf '%s\n' "${line#*$'\t'}"
      return 0
    fi
  done <<<"${cache_blob}"

  return 1
}

docker_gateway_cache_put() {
  local cache_key=$1
  local cache_value=$2

  DOCKER_GATEWAY_RESOLVED_IPV4_CACHE=$(printf '%s\n%s\t%s\n' "${DOCKER_GATEWAY_RESOLVED_IPV4_CACHE}" "${cache_key}" "${cache_value}" | awk 'NF > 0 && !seen[$1]++')
}

docker_gateway_detect_iptables_command() {
  local explicit_command=$1
  local candidate

  if [ -n "${explicit_command}" ]; then
    if docker_gateway_command_exists "${explicit_command}"; then
      printf '%s\n' "${explicit_command}"
      return 0
    fi

    return 1
  fi

  for candidate in iptables iptables-legacy iptables-nft; do
    if docker_gateway_command_exists "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

docker_gateway_tcp_probe() {
  local host=$1
  local port=$2

  if docker_gateway_command_exists timeout; then
    timeout 1 bash -c 'true >/dev/tcp/$1/$2' _ "${host}" "${port}" >/dev/null 2>&1
    return $?
  fi

  if exec 3<>"/dev/tcp/${host}/${port}" 2>/dev/null; then
    exec 3>&-
    exec 3<&-
    return 0
  fi

  return 1
}

docker_gateway_label_value() {
  local container_json=$1
  local label_name=$2

  jq -r --arg label "${label_name}" '.[0].Config.Labels[$label] // empty' <<<"${container_json}"
}

docker_gateway_container_labels_json() {
  local container_json=$1

  jq -nc \
    --argjson container "${container_json}" \
    --arg target_label "${DOCKER_GATEWAY_TARGET_LABEL}" \
    --arg proxy_label "${DOCKER_GATEWAY_PROXY_LABEL}" \
    --arg dns_servers_label "${DOCKER_GATEWAY_DNS_SERVERS_LABEL}" \
    --arg dns_mode_label "${DOCKER_GATEWAY_DNS_MODE_LABEL}" \
    --arg allow_attach_label "${DOCKER_GATEWAY_ALLOW_ATTACH_LABEL}" \
    '($container[0]) as $item | {
      container_name: ($item.Name | ltrimstr("/")),
      network_mode: ($item.HostConfig.NetworkMode // ""),
      target_gateway: ($item.Config.Labels[$target_label] // ""),
      proxy_spec: ($item.Config.Labels[$proxy_label] // ""),
      dns_server: ($item.Config.Labels[$dns_servers_label] // ""),
      dns_mode: ($item.Config.Labels[$dns_mode_label] // ""),
      allow_attach: ($item.Config.Labels[$allow_attach_label] // "")
    }'
}

docker_gateway_is_ipv4() {
  local ip=$1

  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  awk -F. '{ for (i = 1; i <= 4; i++) if ($i < 0 || $i > 255) exit 1 }' <<<"${ip}"
}

docker_gateway_is_safe_hostname_input() {
  local address=$1

  [ -n "${address}" ] || return 1
  [[ "${address}" != -* ]] || return 1
  [[ ! "${address}" =~ [[:space:][:cntrl:]] ]] || return 1
  [ "${#address}" -le 255 ] || return 1
}

docker_gateway_resolve_ipv4_address() {
  local original_address=$1
  local address ip ping_output

  address=$(docker_gateway_trim "${original_address}")

  if docker_gateway_is_ipv4 "${address}"; then
    printf '%s\n' "${address}"
    return 0
  fi

  if [ "${PROXY_SERVER_TO_IP:-true}" != "true" ]; then
    printf '%s\n' "${address}"
    return 0
  fi

  if ! docker_gateway_is_safe_hostname_input "${address}"; then
    docker_gateway_warn "Refusing to resolve unsafe proxy host '${address}'."
    return 1
  fi

  if ip=$(docker_gateway_cache_get "${DOCKER_GATEWAY_RESOLVED_IPV4_CACHE}" "${address}" 2>/dev/null); then
    printf '%s\n' "${ip}"
    return 0
  fi

  if docker_gateway_command_exists timeout; then
    ping_output=$(timeout 2 ping -4 -c 1 -W 1 -- "${address}" 2>/dev/null || true)
  else
    ping_output=$(ping -4 -c 1 -W 1 -- "${address}" 2>/dev/null || true)
  fi

  ip=$(awk -F'[()]' '/PING/ {print $2; exit}' <<<"${ping_output}")
  if docker_gateway_is_ipv4 "${ip}"; then
    docker_gateway_cache_put "${address}" "${ip}"
    docker_gateway_log "Resolved proxy host ${address} to ${ip}."
    printf '%s\n' "${ip}"
    return 0
  fi

  docker_gateway_warn "Unable to resolve proxy host '${address}'. Using the original value."
  docker_gateway_cache_put "${address}" "${address}"
  printf '%s\n' "${address}"
}

docker_gateway_proxy_digest() {
  local payload_json=$1
  local digest=""

  if docker_gateway_command_exists sha256sum; then
    digest=$(printf '%s' "${payload_json}" | sha256sum | awk '{print $1}')
  elif docker_gateway_command_exists shasum; then
    digest=$(printf '%s' "${payload_json}" | shasum -a 256 | awk '{print $1}')
  elif docker_gateway_command_exists openssl; then
    digest=$(printf '%s' "${payload_json}" | openssl dgst -sha256 -r | awk '{print $1}')
  elif docker_gateway_command_exists cksum; then
    digest=$(printf '%s' "${payload_json}" | cksum | awk '{printf "%08x%08x\n", $1, $2}')
  fi

  [ -n "${digest}" ] || return 1
  printf '%s\n' "${digest}"
}

docker_gateway_build_proxy_payload_json() {
  local raw_proxy_spec=$1
  local proxy_spec protocol servers server
  local -a server_list server_array

  proxy_spec=$(docker_gateway_trim "${raw_proxy_spec}")
  if [ -z "${proxy_spec}" ] || [ "${#proxy_spec}" -gt "${DOCKER_GATEWAY_PROXY_SPEC_MAX_LENGTH}" ]; then
    docker_gateway_warn "Invalid proxy spec '${raw_proxy_spec}'."
    return 1
  fi

  protocol=$(docker_gateway_trim "${proxy_spec%%,*}")
  servers=$(docker_gateway_trim "${proxy_spec#*,}")

  if [ -z "${protocol}" ] || [ "${servers}" = "${proxy_spec}" ] || [ -z "${servers}" ]; then
    docker_gateway_warn "Invalid proxy spec '${proxy_spec}'. Expected 'protocol,host:port[:user][:pass]' or 'shadowsocks,host:port:method:password'."
    return 1
  fi

  IFS=',' read -r -a server_list <<<"${servers}"
  if [ "${#server_list[@]}" -gt "${DOCKER_GATEWAY_PROXY_SERVER_MAX_COUNT}" ]; then
    docker_gateway_warn "Proxy spec '${proxy_spec}' exceeds the maximum upstream count (${DOCKER_GATEWAY_PROXY_SERVER_MAX_COUNT})."
    return 1
  fi

  server_array=()
  for server in "${server_list[@]}"; do
    local address port user_or_method pass_or_password json_object
    local -a server_info

    server=$(docker_gateway_trim "${server}")
    [ -n "${server}" ] || continue
    [ "${#server}" -le "${DOCKER_GATEWAY_PROXY_FIELD_MAX_LENGTH}" ] || {
      docker_gateway_warn "Proxy server entry '${server}' is too long."
      continue
    }

    IFS=':' read -r -a server_info <<<"${server}"
    if [[ ${#server_info[@]} -lt 2 ]]; then
      docker_gateway_warn "Proxy server '${server}' is not correctly formatted."
      continue
    fi

    address=$(docker_gateway_trim "${server_info[0]}")
    port=$(docker_gateway_trim "${server_info[1]}")
    user_or_method=$(docker_gateway_trim "${server_info[2]:-}")
    pass_or_password=$(docker_gateway_trim "${server_info[3]:-}")

    if [ -z "${address}" ] || [ "${#address}" -gt "${DOCKER_GATEWAY_PROXY_FIELD_MAX_LENGTH}" ]; then
      docker_gateway_warn "Proxy server '${server}' has an invalid address."
      continue
    fi

    if ! [[ "${port}" =~ ^[0-9]+$ ]]; then
      docker_gateway_warn "Proxy server '${server}' has an invalid port '${port}'."
      continue
    fi

    address=$(docker_gateway_resolve_ipv4_address "${address}") || {
      docker_gateway_warn "Skipping proxy server '${server}' because the host is invalid."
      continue
    }

    case "${protocol}" in
      http|socks)
        json_object=$(jq -nc \
          --arg address "${address}" \
          --argjson port "${port}" \
          --arg user "${user_or_method}" \
          --arg pass "${pass_or_password}" \
          '{
            address: $address,
            port: $port
          } + (if $user != "" and $pass != "" then {
            users: [{user: $user, pass: $pass}]
          } else {} end)')
        ;;
      shadowsocks)
        if [ -z "${user_or_method}" ] || [ -z "${pass_or_password}" ]; then
          docker_gateway_warn "Shadowsocks proxy '${server}' must include method and password."
          continue
        fi
        json_object=$(jq -nc \
          --arg address "${address}" \
          --argjson port "${port}" \
          --arg method "${user_or_method}" \
          --arg password "${pass_or_password}" \
          '{
            address: $address,
            port: $port,
            method: $method,
            password: $password,
            uot: true,
            UoTVersion: 2,
            level: 0
          }')
        ;;
      *)
        docker_gateway_warn "Unsupported proxy protocol '${protocol}' in '${proxy_spec}'."
        return 1
        ;;
    esac

    server_array+=("${json_object}")
  done

  if [ "${#server_array[@]}" -eq 0 ]; then
    docker_gateway_warn "Proxy spec '${proxy_spec}' did not produce any usable upstream servers."
    return 1
  fi

  jq -nc \
    --arg protocol "${protocol}" \
    --argjson servers "$(printf '%s\n' "${server_array[@]}" | jq -s '.')" \
    '{
      protocol: $protocol,
      settings: {
        servers: $servers
      }
    }'
}

docker_gateway_proxy_tag_from_payload() {
  local payload_json=$1
  local digest

  digest=$(docker_gateway_proxy_digest "${payload_json}") || {
    docker_gateway_warn "Unable to compute a stable proxy digest."
    return 1
  }

  printf 'docker-gateway-proxy-%s\n' "${digest:0:12}"
}

docker_gateway_build_outbound_json() {
  local outbound_tag=$1
  local payload_json=$2

  jq -nc \
    --arg tag "${outbound_tag}" \
    --argjson payload "${payload_json}" \
    '$payload + {
      tag: $tag,
      streamSettings: {
        domainStrategy: "AsIs",
        sockopt: {
          mark: 255
        }
      }
    }'
}

docker_gateway_resolve_context() {
  local container_ref container_json gateway_name preferred_network
  local attach_network gateway_ip gateway_subnet
  local -a candidates

  container_ref=${1:-$(docker_gateway_self_container_id)}
  container_json=$(docker inspect "$container_ref" 2>/dev/null) || {
    docker_gateway_error "Unable to inspect gateway container '$container_ref'."
    return 1
  }

  gateway_name=$(jq -r --arg label "$DOCKER_GATEWAY_NAME_LABEL" '.[0].Config.Labels[$label] // empty' <<<"$container_json")
  if [ -z "$gateway_name" ]; then
    docker_gateway_error "Gateway container is missing required label '$DOCKER_GATEWAY_NAME_LABEL'."
    return 1
  fi

  preferred_network=$(jq -r --arg label "$DOCKER_GATEWAY_ATTACH_NETWORK_LABEL" '.[0].Config.Labels[$label] // empty' <<<"$container_json")

  while IFS= read -r network_name; do
    [ -n "$network_name" ] || continue

    local network_json driver subnet ip_address
    network_json=$(docker network inspect "$network_name" 2>/dev/null) || continue
    driver=$(jq -r '.[0].Driver // empty' <<<"$network_json")
    [ "$driver" = "bridge" ] || continue

    subnet=$(jq -r '.[0].IPAM.Config[0].Subnet // empty' <<<"$network_json")
    ip_address=$(jq -r --arg network "$network_name" '.[0].NetworkSettings.Networks[$network].IPAddress // empty' <<<"$container_json")

    [ -n "$subnet" ] || continue
    [ -n "$ip_address" ] || continue

    candidates+=("${network_name}"$'\t'"${ip_address}"$'\t'"${subnet}")
  done < <(jq -r '.[0].NetworkSettings.Networks | keys[]?' <<<"$container_json")

  if [ -n "$preferred_network" ]; then
    local candidate
    for candidate in "${candidates[@]}"; do
      IFS=$'\t' read -r attach_network gateway_ip gateway_subnet <<<"$candidate"
      if [ "$attach_network" = "$preferred_network" ]; then
        jq -n \
          --arg container_id "$(jq -r '.[0].Id' <<<"$container_json")" \
          --arg gateway_name "$gateway_name" \
          --arg attach_network "$attach_network" \
          --arg gateway_ip "$gateway_ip" \
          --arg gateway_subnet "$gateway_subnet" \
          '{
            container_id: $container_id,
            gateway_name: $gateway_name,
            attach_network: $attach_network,
            gateway_ip: $gateway_ip,
            gateway_subnet: $gateway_subnet
          }'
        return 0
      fi
    done

    docker_gateway_error "Gateway attach network '$preferred_network' is not a bridge network attached to this container."
    return 1
  fi

  case "${#candidates[@]}" in
    0)
      docker_gateway_error "Gateway container must be attached to exactly one bridge network, or set '$DOCKER_GATEWAY_ATTACH_NETWORK_LABEL'."
      return 1
      ;;
    1)
      IFS=$'\t' read -r attach_network gateway_ip gateway_subnet <<<"${candidates[0]}"
      ;;
    *)
      docker_gateway_error "Gateway container is attached to multiple bridge networks. Set '$DOCKER_GATEWAY_ATTACH_NETWORK_LABEL' to choose one."
      return 1
      ;;
  esac

  jq -n \
    --arg container_id "$(jq -r '.[0].Id' <<<"$container_json")" \
    --arg gateway_name "$gateway_name" \
    --arg attach_network "$attach_network" \
    --arg gateway_ip "$gateway_ip" \
    --arg gateway_subnet "$gateway_subnet" \
    '{
      container_id: $container_id,
      gateway_name: $gateway_name,
      attach_network: $attach_network,
      gateway_ip: $gateway_ip,
      gateway_subnet: $gateway_subnet
    }'
}

docker_gateway_validate_unique_name() {
  local gateway_name self_container_id
  local -a running_gateways

  gateway_name=$1
  self_container_id=$2

  mapfile -t running_gateways < <(docker ps -q --no-trunc --filter "label=${DOCKER_GATEWAY_NAME_LABEL}=${gateway_name}")
  for container_id in "${running_gateways[@]}"; do
    [ -n "$container_id" ] || continue
    if [ "$container_id" != "$self_container_id" ]; then
      docker_gateway_error "Found another running gateway with ${DOCKER_GATEWAY_NAME_LABEL}=${gateway_name}: $container_id"
      return 1
    fi
  done
}
