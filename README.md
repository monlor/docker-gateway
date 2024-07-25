## Introduction

docker-xray implements a transparent proxy gateway within Docker containers to provide proxy services to other containers. It can route traffic based on different containers to different proxy servers and supports http/socks/vmess/ss protocols.

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
  -v /var/run/docker:/var/run/docker \
  --network=gateway \
  --ip=172.100.0.2 \
  --restart=unless-stopped \
  ghcr.io/monlor/docker-gateway:main
```

### Connect gateway

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

`RULE_TAG_*`: Outbound ip address list with tag *

`OUTBOUND_SERVER_*`: The outbound proxy list tag is named *

`NON_CN_DNS_OUT`: Non-Chinese dns outbound (default direct)

`CN_DNS_OUT`: Chinese dns outbound (default direct)

`DEFAULT_OUT`: default outbound

`LAN_SEGMENT`: lan network segment (default 172.100.0.0/24)