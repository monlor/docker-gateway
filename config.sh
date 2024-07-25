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
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["all-in"],
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
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
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
        "destOverride": ["http", "tls"]
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy",
          "mark": 255
        }
      }
    },
    {
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
    "servers": [
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
      "8.8.8.8",
      "1.1.1.1"
    ]
  }
}
EOF

if ! (env | grep ^RULE_TAG_ &> /dev/null) then
  echo "can't found env RULE_TAG_*!"
  exit 1
fi
# parse RULE_TAG_*
for var in $(env | grep ^RULE_TAG_); do
  tag=${var%%=*}
  tag=${tag#RULE_TAG_}
  ips=${var#*=}
  
  # ip to json array
  ip_array=$(echo $ips | sed 's/,/","/g; s/^/["/; s/$/"]/')
  
  # update rules
  jq ".routing.rules = [{\"type\": \"field\", \"source\": $ip_array, \"domain\": [\"geosite:geolocation-!cn\"], \"outboundTag\": \"$tag\"}] + .routing.rules" /etc/xray/config.json > /tmp/config.json.tmp && mv /tmp/config.json.tmp /etc/xray/config.json
done

if ! (env | grep ^OUTBOUND_SERVER_ &> /dev/null) then
  echo "can't found env OUTBOUND_SERVER_*!"
  exit 1
fi
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
    
    if [[ "$protocol" == "http" || "$protocol" == "socks" ]]; then
      server_array+=("{
        \"address\": \"$address\",
        \"port\": $port,
        \"users\": [{
          \"user\": \"$user\",
          \"pass\": \"$pass\"
        }]
      }")
    elif [[ "$protocol" == "vmess" ]]; then
      # get alterId and security
      alterId=${SERVER_INFO[4]:-64}  # default 64
      security=${SERVER_INFO[5]:-auto}  # default auto

      server_array+=("{
        \"address\": \"$address\",
        \"port\": $port,
        \"users\": [{
          \"id\": \"$user\",
          \"alterId\": $alterId,
          \"security\": \"$security\"
        }]
      }")
    elif [[ "$protocol" == "ss" ]]; then
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
      \"servers\": $(IFS=,; echo "[${server_array[*]}]")
    },
    \"streamSettings\": {
      \"sockopt\": {
        \"mark\": 255
      }
    }
  }]" /etc/xray/config.json > /tmp/config.json.tmp && mv /tmp/config.json.tmp /etc/xray/config.json
done
