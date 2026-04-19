#!/bin/bash
set -euo pipefail

LOG_LEVEL=${LOG_LEVEL:-info}
XRAY_CONFIG_DIR=${XRAY_CONFIG_DIR:-/etc/xray}
XRAY_CONFIG_PATH="${XRAY_CONFIG_DIR}/config.json"
XRAY_STATIC_RULES_PATH="${XRAY_CONFIG_DIR}/static-routing-rules.json"
XRAY_DEFAULT_RULE_PATH="${XRAY_CONFIG_DIR}/default-routing-rule.json"
XRAY_API_PORT=${XRAY_API_PORT:-10085}
XRAY_LOG_LEVEL=${LOG_LEVEL}
XRAY_ACCESS_LOG=none
XRAY_DNS_LOG=false

case "${XRAY_LOG_LEVEL}" in
  debug)
    XRAY_ACCESS_LOG=""
    XRAY_DNS_LOG=true
    ;;
  info)
    ;;
  warning|error|none)
    ;;
  warn)
    XRAY_LOG_LEVEL=warning
    ;;
  *)
    XRAY_LOG_LEVEL=info
    ;;
esac

mkdir -p "${XRAY_CONFIG_DIR}"

jq -n \
  --arg cn_out "${CN_OUT:-direct}" \
  --arg ads_all_out "${ADS_ALL_OUT:-block}" \
  '[
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
  --arg log_level "${XRAY_LOG_LEVEL}" \
  --arg access_log "${XRAY_ACCESS_LOG}" \
  --argjson dns_log "${XRAY_DNS_LOG}" \
  --arg api_listen "127.0.0.1:${XRAY_API_PORT}" \
  --arg transparent_port "${PORT:-12345}" \
  --arg socks_port "${SOCKS_PORT:-1080}" \
  --slurpfile static_rules "${XRAY_STATIC_RULES_PATH}" \
  --slurpfile default_rule "${XRAY_DEFAULT_RULE_PATH}" \
  '{
    log: {
      loglevel: $log_level,
      access: $access_log,
      dnsLog: $dns_log
    },
    api: {
      tag: "api",
      listen: $api_listen,
      services: ["RoutingService", "HandlerService"]
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
