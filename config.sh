#!/bin/bash

# log level
LOG_LEVEL=${LOG_LEVEL:-info}

# init config
cat > /etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "${LOG_LEVEL}"
  },
  "routing": {
    "domainMatcher": "mph",
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["all-in", "socks-in"],
        "port": 53,
        "network": "udp",
        "outboundTag": "dns-out"
      },
      { 
        "type": "field", 
        "ip": [ "8.8.8.8", "1.1.1.1" ] , 
        "outboundTag": "${NON_CN_DNS_OUT:-direct}" 
      },
			{ 
        "type": "field", 
        "ip": [ "119.29.29.29", "223.5.5.5" ], 
        "outboundTag": "${CN_DNS_OUT:-direct}" 
      },
      {
        "type": "field",
        "domain": [ "geosite:geolocation-cn" ],
        "outboundTag": "${CN_OUT:-direct}"
      },
      {
        "type": "field",
        "ip": [ "geoip:cn" ],
        "outboundTag": "${CN_OUT:-direct}"
      },
      {
        "type": "field",
        "ip": [ "geoip:private" ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "inboundTag": ["all-in", "socks-in"],
        "port": 123,
        "network": "udp",
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "${ADS_ALL_OUT:-block}"
      },
      {
        "type": "field",
        "network": "udp,tcp",
        "outboundTag": "${DEFAULT_OUT:-direct}"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "all-in",
      "port": ${PORT:-12345},
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy",
          "mark": 255
        }
      }
    },
    {
      "tag": "socks-in",
      "port": ${SOCKS_PORT:-1080},
      "protocol": "socks",
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      },
      "settings": {
        "auth": "noauth"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "streamSettings": {
        "sockopt": {
          "mark": 255
        }
      }
    },
    {
      "tag": "dns-out",
      "protocol": "dns",
      "settings": {
        "domainStrategy": "UseIP"
      },
      "streamSettings": {
        "sockopt": {
          "mark": 255
        }
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {
        "response": {
          "type": "http"
        }
      }
    }
  ],
  "dns": {
    "hosts": {
      "domain:googleapis.cn": "googleapis.com",
      "dns.google": "8.8.8.8"
    },
    "servers": [
      "https://1.1.1.1/dns-query",
      {
        "address": "119.29.29.29",
        "port": 53,
        "domains": ["geosite:cn"],
        "expectIPs": ["geoip:cn"]
      },
      {
        "address": "223.5.5.5",
        "port": 53,
        "domains": ["geosite:cn"],
        "expectIPs": ["geoip:cn"]
      },
      "https://dns.google/dns-query",
      "8.8.8.8",
      "1.1.1.1"
    ],
    "queryStrategy": "UseIP",
    "tag": "dns_inbound"
  }
}
EOF

# parse RULE_TAG_*
for var in $(env | grep ^RULE_TAG_); do
  tag=${var%%=*}
  tag=${tag#RULE_TAG_}
  ips=${var#*=}
  
  # ip to json array
  ip_array=$(echo $ips | sed 's/,/","/g; s/^/["/; s/$/"]/')
  
  # update rules
  # geosite:geolocation-!cn
  rule_domains=""
  if [ -n "${RULE_DOMAIN:-}" ]; then
    rule_domains=", \"domain\": [\"$(echo "${RULE_DOMAIN:-}" | sed -e 's/,/","/g')\"]"
  fi
  jq ".routing.rules = [{\"type\": \"field\", \"source\": $ip_array ${rule_domains}, \"outboundTag\": \"$tag\"}] + .routing.rules" /etc/xray/config.json > /tmp/config.json.tmp && mv /tmp/config.json.tmp /etc/xray/config.json
done

# parse OUTBOUND_SERVER_*
for var in $(env | grep ^OUTBOUND_SERVER_); do
  tag=${var%%=*}
  tag=${tag#OUTBOUND_SERVER_}
  value=${var#*=}
  
  # get protocol and servers
  protocol=${value%%,*}
  servers=${value#*,}
  
  IFS=',' read -ra SERVER_LIST <<< "$servers"
  
  server_array=()

  outbound_type="servers"
  
  for server in "${SERVER_LIST[@]}"; do
    IFS=':' read -ra SERVER_INFO <<< "$server"
    
    if [[ ${#SERVER_INFO[@]} -lt 2 ]]; then
      echo "Error: server information '$server' is not correctly formatted."
      continue
    fi
    
    address=${SERVER_INFO[0]}
    port=${SERVER_INFO[1]}
    user=${SERVER_INFO[2]:-}  # could be null
    pass=${SERVER_INFO[3]:-}  # could be null
    
    # check port is number
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
      echo "Error: port '$port' is not a valid number."
      continue
    fi

    # resolve domain to ip
    if [ "${PROXY_SERVER_TO_IP:-true}" = "true" ]; then
      if [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$address is a ip address"
      else
        ip=$(ping -4 -c 1 "$address" | awk -F'[()]' '/PING/ {print $2}')
        if [ -n "$ip" ]; then
            echo "nslookup $address to $ip"
            address=${ip}
        else
            echo "can't resolve: $address"
        fi
      fi
    fi
    
    if [[ "$protocol" == "http" || "$protocol" == "socks" ]]; then
      json_object="{ \"address\": \"$address\", \"port\": $port"
      if [ -n "$user" ] && [ -n "$pass" ]; then
          json_object+=", \"users\": [{ \"user\": \"$user\", \"pass\": \"$pass\" }] }"
      else
          json_object+=" }"
      fi
      server_array=("$json_object")
    elif [[ "$protocol" == "shadowsocks" ]]; then
      server_array+=("{
        \"address\": \"$address\",
        \"port\": $port,
        \"method\": \"$user\",
        \"password\": \"$pass\",
        \"uot\": true,
        \"UoTVersion\": 2,
        \"level\": 0
      }")
    else
      echo "Error: Unsupported protocol '$protocol'."
      continue
    fi
  done
  
  # update outbounds
  jq ".outbounds += [{
    \"tag\": \"$tag\",
    \"protocol\": \"$protocol\",
    \"settings\": {
      \"${outbound_type}\": $(IFS=,; echo "[${server_array[*]}]")
    },
    \"streamSettings\": {
      \"domainStrategy\": \"AsIs\",
      \"sockopt\": {
        \"mark\": 255
      }
    }
  }]" /etc/xray/config.json > /tmp/config.json.tmp && mv /tmp/config.json.tmp /etc/xray/config.json

done
