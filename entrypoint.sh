#!/bin/bash
set -e

echo "generate iptables rules ..."

# ip rule
ip rule add fwmark 1 table 100 
ip route add local 0.0.0.0/0 dev lo table 100

# alias iptables-legacy
alias iptables=iptables-legacy

# transparent
iptables -t mangle -N XRAY
iptables -t mangle -A XRAY -d 127.0.0.1/32 -j RETURN
iptables -t mangle -A XRAY -d 224.0.0.0/4 -j RETURN 
iptables -t mangle -A XRAY -d 255.255.255.255/32 -j RETURN
iptables -t mangle -A XRAY -d 127.0.0.11/32 -p tcp -j RETURN 
iptables -t mangle -A XRAY -d 127.0.0.53/32 -p tcp -j RETURN  
iptables -t mangle -A XRAY -d ${LAN_SEGMENT:-172.100.0.0/24} -p tcp -j RETURN 
iptables -t mangle -A XRAY -d ${LAN_SEGMENT:-172.100.0.0/24} -p udp ! --dport 53 -j RETURN 
iptables -t mangle -A XRAY -j RETURN -m mark --mark 0xff   
iptables -t mangle -A XRAY -p udp -j TPROXY --on-ip 127.0.0.1 --on-port ${PORT:-12345} --tproxy-mark 1 
iptables -t mangle -A XRAY -p tcp -j TPROXY --on-ip 127.0.0.1 --on-port ${PORT:-12345} --tproxy-mark 1 
iptables -t mangle -A PREROUTING -j XRAY 

iptables -t mangle -N XRAY_MASK 
iptables -t mangle -A XRAY_MASK -d 224.0.0.0/4 -j RETURN 
iptables -t mangle -A XRAY_MASK -d 255.255.255.255/32 -j RETURN 
iptables -t mangle -A XRAY_MASK -d 127.0.0.11/32 -p tcp -j RETURN 
iptables -t mangle -A XRAY_MASK -d 127.0.0.53/32 -p tcp -j RETURN 
iptables -t mangle -A XRAY_MASK -d ${LAN_SEGMENT:-172.100.0.0/24} -p tcp -j RETURN # 直连局域网
iptables -t mangle -A XRAY_MASK -d ${LAN_SEGMENT:-172.100.0.0/24} -p udp ! --dport 53 -j RETURN # 直连局域网，53 端口除外（因为要使用 XRAY 的 DNS）
iptables -t mangle -A XRAY_MASK -j RETURN -m mark --mark 0xff    # 直连 SO_MARK 为 0xff 的流量(0xff 是 16 进制数，数值上等同与上面XRAY 配置的 255)，此规则目的是避免代理本机(网关)流量出现回环问题
iptables -t mangle -A XRAY_MASK -p udp -j MARK --set-mark 1   # 给 UDP 打标记，重路由
iptables -t mangle -A XRAY_MASK -p tcp -j MARK --set-mark 1   # 给 TCP 打标记，重路由
iptables -t mangle -A OUTPUT -j XRAY_MASK # 应用规则

iptables -t mangle -N DIVERT
iptables -t mangle -A DIVERT -j MARK --set-mark 1
iptables -t mangle -A DIVERT -j ACCEPT
iptables -t mangle -I PREROUTING -p tcp -m socket -j DIVERT

echo "generate xray config ..."
/config.sh

echo "starting docker event ..."
/docker-gateway-manager.sh &

local_ip=$(ip a | grep inet | grep -Ev 'inet6|127.0.0.1' | awk '{print$2}' | cut -d'/' -f1)
echo "gateway ip: ${local_ip}"

echo "starting xray ..."
exec xray -config /etc/xray/config.json