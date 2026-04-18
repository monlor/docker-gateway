#!/bin/bash
set -euo pipefail

LOG_LEVEL=${LOG_LEVEL:-info}
XRAY_CONFIG_DIR=${XRAY_CONFIG_DIR:-/etc/xray}
XRAY_CONFIG_PATH="${XRAY_CONFIG_DIR}/config.json"
XRAY_STATIC_RULES_PATH="${XRAY_CONFIG_DIR}/static-routing-rules.json"
XRAY_DEFAULT_RULE_PATH="${XRAY_CONFIG_DIR}/default-routing-rule.json"
XRAY_API_PORT=${XRAY_API_PORT:-10085}

mkdir -p "${XRAY_CONFIG_DIR}"

jq -n \
  --arg default_dns_out "${DEFAULT_DNS_OUT:-direct}" \
  --arg non_cn_dns_out "${NON_CN_DNS_OUT:-direct}" \
  --arg cn_dns_out "${CN_DNS_OUT:-direct}" \
  --arg cn_out "${CN_OUT:-direct}" \
  --arg ads_all_out "${ADS_ALL_OUT:-block}" \
  '[
    {
      ruleTag: "dns-inbound",
      type: "field",
      inboundTag: ["all-in", "socks-in"],
      port: 53,
      network: "udp",
      outboundTag: $default_dns_out
    },
    {
      ruleTag: "non-cn-dns",
      type: "field",
      ip: ["8.8.8.8", "1.1.1.1"],
      outboundTag: $non_cn_dns_out
    },
    {
      ruleTag: "cn-dns",
      type: "field",
      ip: ["119.29.29.29", "223.5.5.5"],
      outboundTag: $cn_dns_out
    },
    {
      ruleTag: "cn-domain",
      type: "field",
      domain: ["geosite:geolocation-cn"],
      outboundTag: $cn_out
    },
    {
      ruleTag: "cn-ip",
      type: "field",
      ip: ["geoip:cn"],
      outboundTag: $cn_out
    },
    {
      ruleTag: "private-ip",
      type: "field",
      ip: ["geoip:private"],
      outboundTag: "direct"
    },
    {
      ruleTag: "bittorrent",
      type: "field",
      protocol: ["bittorrent"],
      outboundTag: "direct"
    },
    {
      ruleTag: "ntp",
      type: "field",
      inboundTag: ["all-in", "socks-in"],
      port: 123,
      network: "udp",
      outboundTag: "direct"
    },
    {
      ruleTag: "ads",
      type: "field",
      domain: ["geosite:category-ads-all"],
      outboundTag: $ads_all_out
    }
  ]' > "${XRAY_STATIC_RULES_PATH}"

jq -n \
  --arg default_out "${DEFAULT_OUT:-direct}" \
  '{
    ruleTag: "default-outbound",
    type: "field",
    network: "udp,tcp",
    outboundTag: $default_out
  }' > "${XRAY_DEFAULT_RULE_PATH}"

jq -n \
  --arg log_level "${LOG_LEVEL}" \
  --arg api_listen "127.0.0.1:${XRAY_API_PORT}" \
  --arg transparent_port "${PORT:-12345}" \
  --arg socks_port "${SOCKS_PORT:-1080}" \
  --slurpfile static_rules "${XRAY_STATIC_RULES_PATH}" \
  --slurpfile default_rule "${XRAY_DEFAULT_RULE_PATH}" \
  '{
    log: {
      loglevel: $log_level
    },
    api: {
      tag: "api",
      listen: $api_listen,
      services: ["RoutingService"]
    },
    routing: {
      domainMatcher: "mph",
      domainStrategy: "IPIfNonMatch",
      rules: ($static_rules[0] + [$default_rule[0]])
    },
    inbounds: [
      {
        tag: "all-in",
        port: ($transparent_port | tonumber),
        protocol: "dokodemo-door",
        settings: {
          network: "tcp,udp",
          followRedirect: true
        },
        sniffing: {
          enabled: true,
          destOverride: ["http", "tls", "quic"],
          routeOnly: false
        },
        streamSettings: {
          sockopt: {
            tproxy: "tproxy",
            mark: 255
          }
        }
      },
      {
        tag: "socks-in",
        port: ($socks_port | tonumber),
        protocol: "socks",
        sniffing: {
          enabled: true,
          destOverride: ["http", "tls"]
        },
        settings: {
          auth: "noauth"
        }
      }
    ],
    outbounds: [
      {
        tag: "direct",
        protocol: "freedom",
        settings: {
          domainStrategy: "UseIPv4"
        },
        streamSettings: {
          sockopt: {
            mark: 255
          }
        }
      },
      {
        tag: "dns-out",
        protocol: "dns",
        settings: {
          domainStrategy: "UseIP"
        },
        streamSettings: {
          sockopt: {
            mark: 255
          }
        }
      },
      {
        tag: "block",
        protocol: "blackhole",
        settings: {
          response: {
            type: "http"
          }
        }
      }
    ],
    dns: {
      hosts: {
        "domain:googleapis.cn": "googleapis.com",
        "dns.google": "8.8.8.8"
      },
      servers: [
        "https://1.1.1.1/dns-query",
        {
          address: "119.29.29.29",
          port: 53,
          domains: ["geosite:cn"],
          expectIPs: ["geoip:cn"]
        },
        {
          address: "223.5.5.5",
          port: 53,
          domains: ["geosite:cn"],
          expectIPs: ["geoip:cn"]
        },
        "https://dns.google/dns-query",
        "8.8.8.8",
        "1.1.1.1"
      ],
      queryStrategy: "UseIP",
      tag: "dns_inbound"
    }
  }' > "${XRAY_CONFIG_PATH}"

while IFS= read -r var; do
  [ -n "$var" ] || continue

  tag=${var%%=*}
  tag=${tag#OUTBOUND_SERVER_}
  value=${var#*=}
  protocol=${value%%,*}
  servers=${value#*,}

  IFS=',' read -ra SERVER_LIST <<<"${servers}"
  server_array=()
  outbound_type="servers"

  for server in "${SERVER_LIST[@]}"; do
    IFS=':' read -ra SERVER_INFO <<<"${server}"

    if [[ ${#SERVER_INFO[@]} -lt 2 ]]; then
      echo "Error: server information '${server}' is not correctly formatted."
      continue
    fi

    address=${SERVER_INFO[0]}
    port=${SERVER_INFO[1]}
    user=${SERVER_INFO[2]:-}
    pass=${SERVER_INFO[3]:-}

    if ! [[ "${port}" =~ ^[0-9]+$ ]]; then
      echo "Error: port '${port}' is not a valid number."
      continue
    fi

    if [ "${PROXY_SERVER_TO_IP:-true}" = "true" ]; then
      if [[ "${address}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "${address} is a ip address"
      else
        ip=$(ping -4 -c 1 "${address}" | awk -F'[()]' '/PING/ {print $2}')
        if [ -n "${ip}" ]; then
          echo "nslookup ${address} to ${ip}"
          address=${ip}
        else
          echo "can't resolve: ${address}"
        fi
      fi
    fi

    if [[ "${protocol}" == "http" || "${protocol}" == "socks" ]]; then
      json_object="{\"address\":\"${address}\",\"port\":${port}"
      if [ -n "${user}" ] && [ -n "${pass}" ]; then
        json_object+=",\"users\":[{\"user\":\"${user}\",\"pass\":\"${pass}\"}]}"
      else
        json_object+="}"
      fi
      server_array+=("${json_object}")
    elif [[ "${protocol}" == "shadowsocks" ]]; then
      server_array+=("{
        \"address\": \"${address}\",
        \"port\": ${port},
        \"method\": \"${user}\",
        \"password\": \"${pass}\",
        \"uot\": true,
        \"UoTVersion\": 2,
        \"level\": 0
      }")
    else
      echo "Error: Unsupported protocol '${protocol}'."
      continue
    fi
  done

  jq ".outbounds += [{
    \"tag\": \"${tag}\",
    \"protocol\": \"${protocol}\",
    \"settings\": {
      \"${outbound_type}\": $(IFS=,; echo "[${server_array[*]}]")
    },
    \"streamSettings\": {
      \"domainStrategy\": \"AsIs\",
      \"sockopt\": {
        \"mark\": 255
      }
    }
  }]" "${XRAY_CONFIG_PATH}" > /tmp/config.json.tmp && mv /tmp/config.json.tmp "${XRAY_CONFIG_PATH}"
done < <(env | grep '^OUTBOUND_SERVER_' || true)
