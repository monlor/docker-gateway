## Introduction

**English** | [简体中文](/README-CN.md)

The docker-gateway project implements a proxy server gateway on top of Docker. The primary goal is to assign different proxy nodes to different containers. The underlying principle is to launch a transparent proxy gateway service, which redirects the default gateway of other containers on the same virtual network interface to the gateway service. It then uses Xray to achieve traffic splitting.

## Installation

### Init gateway

```
# create network
docker network create --subnet=172.100.0.0/24 gateway
# run
docker run -d \
  --name docker-gateway \
  -e RULE_TAG_HK=172.100.0.12/32,1.1.1.1/32 \
  -e OUTBOUND_SERVER_HK=http,1.1.1.1:443:user1:pass1 \
  --privileged=true \
  --pid=host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --network=gateway \
  --ip=172.100.0.2 \
  --restart=unless-stopped \
  ghcr.io/monlor/docker-gateway:main
```

### Connect gateway (test)

```bash
docker run -d \
  --name=nginx \
  --network gateway \
  -e GATEWAY_IP=172.100.0.2 \
  --restart=unless-stopped \
  nginx
```

## Evironment

`PORT`: transparent port

`SOCKS_PORT`: inbound socks port

`RULE_TAG_*`: List of LAN IP addresses for the network egress to outbound tag *

`OUTBOUND_SERVER_*`: List of egress proxy servers with tag *, format: `protocol,ip:port:user:(pass/security)[:alterId],...`, Supported protocols: ss/http/socks/vmess

`NON_CN_DNS_OUT`: Non-Chinese dns server outbound (default direct)

`CN_DNS_OUT`: Chinese dns server outbound (default direct)

`DEFAULT_OUT`: default outbound

`LAN_SEGMENT`: lan network segment (default 172.100.0.0/24)

## Sponsorship

<a href="https://www.buymeacoffee.com/monlor" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>
