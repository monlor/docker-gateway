#!/bin/bash
set -e

echo "generate iptables rules ..."

# ip rule
ip rule add fwmark 1 table 100 
ip route add local 0.0.0.0/0 dev lo table 100

IPTABLES=${IPTABLES_COMMAND:-iptables-legacy}

# transparent
${IPTABLES} -t mangle -N XRAY
${IPTABLES} -t mangle -A XRAY -d 127.0.0.1/24 -j RETURN
${IPTABLES} -t mangle -A XRAY -d 224.0.0.0/4 -j RETURN 
${IPTABLES} -t mangle -A XRAY -d 255.255.255.255/32 -j RETURN
${IPTABLES} -t mangle -A XRAY -d ${LAN_SEGMENT:-172.100.0.0/24} -p tcp -j RETURN 
${IPTABLES} -t mangle -A XRAY -d ${LAN_SEGMENT:-172.100.0.0/24} -p udp ! --dport 53 -j RETURN 
${IPTABLES} -t mangle -A XRAY -j RETURN -m mark --mark 0xff   
${IPTABLES} -t mangle -A XRAY -p udp -j TPROXY --on-ip 127.0.0.1 --on-port ${PORT:-12345} --tproxy-mark 1 
${IPTABLES} -t mangle -A XRAY -p tcp -j TPROXY --on-ip 127.0.0.1 --on-port ${PORT:-12345} --tproxy-mark 1 
${IPTABLES} -t mangle -A PREROUTING -j XRAY 

if [ "${LOCAL_PROXY_ENABLED:-false}" = "true" ]; then
  ${IPTABLES} -t mangle -N XRAY_MASK 
  ${IPTABLES} -t mangle -A XRAY_MASK -d 127.0.0.1/24 -j RETURN
  ${IPTABLES} -t mangle -A XRAY_MASK -d 224.0.0.0/4 -j RETURN 
  ${IPTABLES} -t mangle -A XRAY_MASK -d 255.255.255.255/32 -j RETURN 
  ${IPTABLES} -t mangle -A XRAY_MASK -d ${LAN_SEGMENT:-172.100.0.0/24} -p tcp -j RETURN
  ${IPTABLES} -t mangle -A XRAY_MASK -d ${LAN_SEGMENT:-172.100.0.0/24} -p udp ! --dport 53 -j RETURN 
  ${IPTABLES} -t mangle -A XRAY_MASK -j RETURN -m mark --mark 0xff  
  ${IPTABLES} -t mangle -A XRAY_MASK -p udp -j MARK --set-mark 1  
  ${IPTABLES} -t mangle -A XRAY_MASK -p tcp -j MARK --set-mark 1  
  ${IPTABLES} -t mangle -A OUTPUT -j XRAY_MASK 
fi

${IPTABLES} -t mangle -N DIVERT
${IPTABLES} -t mangle -A DIVERT -j MARK --set-mark 1
${IPTABLES} -t mangle -A DIVERT -j ACCEPT
${IPTABLES} -t mangle -I PREROUTING -p tcp -m socket -j DIVERT

echo "generate xray config ..."
/config.sh

echo "starting docker event ..."
/docker-gateway-manager.sh &

local_ip=$(ip a | grep inet | grep -Ev 'inet6|127.0.0.1' | awk '{print$2}' | cut -d'/' -f1)
echo "gateway ip: ${local_ip}"

echo "starting xray ..."
exec xray -config /etc/xray/config.json