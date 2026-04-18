#!/bin/bash

DOCKER_GATEWAY_NAME_LABEL=${DOCKER_GATEWAY_NAME_LABEL:-docker-gateway.name}
DOCKER_GATEWAY_ATTACH_NETWORK_LABEL=${DOCKER_GATEWAY_ATTACH_NETWORK_LABEL:-docker-gateway.attach-network}
DOCKER_GATEWAY_TARGET_LABEL=${DOCKER_GATEWAY_TARGET_LABEL:-docker-gateway.gateway}
DOCKER_GATEWAY_OUTBOUND_LABEL=${DOCKER_GATEWAY_OUTBOUND_LABEL:-docker-gateway.outbound}

docker_gateway_log() {
  printf '[docker-gateway] %s\n' "$*"
}

docker_gateway_warn() {
  printf '[docker-gateway] WARN: %s\n' "$*" >&2
}

docker_gateway_error() {
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

  mapfile -t running_gateways < <(docker ps -q --filter "label=${DOCKER_GATEWAY_NAME_LABEL}=${gateway_name}")
  for container_id in "${running_gateways[@]}"; do
    [ -n "$container_id" ] || continue
    if [ "$container_id" != "$self_container_id" ]; then
      docker_gateway_error "Found another running gateway with ${DOCKER_GATEWAY_NAME_LABEL}=${gateway_name}: $container_id"
      return 1
    fi
  done
}
