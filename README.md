## Introduction

**English** | [简体中文](/README-CN.md)

The docker-gateway project implements a proxy server gateway on top of Docker. The primary goal is to assign different proxy nodes to different containers. The underlying principle is to launch a transparent proxy gateway service, which redirects the default gateway of other containers on the same virtual network interface to the gateway service. It then uses Xray to achieve traffic splitting.

## Installation

This release is a breaking change. `GATEWAY_IP`, `RULE_TAG_*`, and `LAN_SEGMENT` are removed.

### Init gateway

```
docker run -d \
  --name docker-gateway \
  --label docker-gateway.name=main \
  -e OUTBOUND_SERVER_HK=http,1.1.1.1:443:user1:pass1 \
  --privileged=true \
  --pid=host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --restart=unless-stopped \
  ghcr.io/monlor/docker-gateway:main
```

If the gateway container is attached to multiple bridge networks, set `docker-gateway.attach-network` to choose the managed network:

```bash
docker run -d \
  --name docker-gateway \
  --network frontend \
  --label docker-gateway.name=main \
  --label docker-gateway.attach-network=frontend \
  -e OUTBOUND_SERVER_HK=http,1.1.1.1:443:user1:pass1 \
  --privileged=true \
  --pid=host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --restart=unless-stopped \
  ghcr.io/monlor/docker-gateway:main
```

### Connect gateway (test)

```bash
docker run -d \
  --name=nginx \
  --label docker-gateway.gateway=main \
  --label docker-gateway.outbound=HK \
  --restart=unless-stopped \
  nginx
```

The app container no longer needs a gateway IP. The manager finds the gateway's IP automatically and connects the app container to the gateway network when needed.

## Container Labels

`docker-gateway.name`: required on the gateway container; logical gateway name

`docker-gateway.attach-network`: optional on the gateway container; required only when the gateway joins multiple bridge networks

`docker-gateway.gateway`: required on the app container; points to the target gateway logical name

`docker-gateway.outbound`: optional on the app container; must match the suffix of an `OUTBOUND_SERVER_*` environment variable such as `HK`

## Environment

`PORT`: transparent proxy port

`SOCKS_PORT`: inbound socks port

`OUTBOUND_SERVER_*`: List of egress proxy servers with tag *, format: `protocol,ip:port:(user|method):pass,...`, Supported protocols: shadowsocks/http/socks

`RULE_DOMAIN`: Domain list appended to label-driven outbound rules (default none)

`PROXY_SERVER_TO_IP`: Resolve the proxy server domain as IP (default true)

`NON_CN_DNS_OUT`: Non-Chinese dns server outbound tag (default direct)

`CN_DNS_OUT`: Chinese dns server outbound tag (default direct)

`CN_OUT`: Chinese ip and domain outbound tag (default direct)

`DEFAULT_OUT`: default outbound

`XRAY_API_PORT`: localhost Xray RoutingService port (default 10085)

## Outbound Example

* Add HK's socks5 proxy and let app containers labeled with `docker-gateway.outbound=HK` use it

```
OUTBOUND_SERVER_HK=socks,1.1.1.1:2222:user:pass
```

## Migration

| Old | New |
| --- | --- |
| `GATEWAY_IP=172.100.0.2` | `--label docker-gateway.gateway=<gateway-name>` |
| `RULE_TAG_HK=172.100.0.10/32` | `--label docker-gateway.outbound=HK` on the app container |
| Manual `docker network create ...` | Let Docker assign the gateway network, or set `docker-gateway.attach-network` when multiple bridge networks are attached |
| Fixed `--ip` on gateway | Omit it; the manager discovers the gateway IP automatically |

## Sponsorship

<a href="https://www.buymeacoffee.com/monlor" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>
