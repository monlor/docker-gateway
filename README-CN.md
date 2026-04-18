## 介绍

[English](/README.md) | **简体中文**

docker-gateway 项目在 Docker 之上实现了一个代理服务器网关。主要目标是为不同的容器分配不同的代理节点。其底层原理是启动一个透明代理网关服务, 将同一虚拟网络接口下其他容器的默认网关重定向到网关服务，使用 Xray 实现流量分流。

## 安装

这个版本是破坏性变更，已经移除 `GATEWAY_IP`、`RULE_TAG_*` 和 `LAN_SEGMENT`。

### 初始化网关

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

如果网关容器加入了多个 bridge 网络，需要通过 `docker-gateway.attach-network` 指定管理哪个网络：

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

### 测试连接网关

```
docker run -d \
  --name=nginx \
  --label docker-gateway.gateway=main \
  --label docker-gateway.outbound=HK \
  --restart=unless-stopped \
  nginx
```

应用容器不再需要配置网关 IP。manager 会自动识别 gateway 的 IP，并在需要时把应用容器接入 gateway 所在网络。

## 容器 Label

`docker-gateway.name`: 网关容器必填，表示逻辑网关名

`docker-gateway.attach-network`: 网关容器可选；仅在网关加入多个 bridge 网络时需要指定

`docker-gateway.gateway`: 应用容器必填，指向目标网关逻辑名

`docker-gateway.outbound`: 应用容器可选；必须和某个 `OUTBOUND_SERVER_*` 的后缀完全一致，例如 `HK`

## 环境变量

`PORT`: 透明代理端口

`SOCKS_PORT`: 入站 Socks 端口

`OUTBOUND_SERVER_*`: 创建标签 * 的出站代理服务器列表, 格式: `协议,ip:port:(user|method):pass,...`, 支持的协议: shadowsocks/http/socks

`RULE_DOMAIN`: 附加到 label 动态路由上的域名列表 (默认 空)

`PROXY_SERVER_TO_IP`: 解析代理服务器域名为ip (默认 true)

`NON_CN_DNS_OUT`: 非中国 DNS 服务器出站tag (默认 direct)

`CN_DNS_OUT`: 中国 DNS 服务器出站tag (默认 direct)

`CN_OUT`: 中国IP和域名出站tag (默认 direct)

`DEFAULT_OUT`: 默认出站tag

`XRAY_API_PORT`: 本地 Xray RoutingService 端口 (默认 10085)

## 出站示例

* 添加 HK 的 socks5 代理，让带有 `docker-gateway.outbound=HK` 的应用容器走 HK 出口

```
OUTBOUND_SERVER_HK=socks,1.1.1.1:2222:user:pass
```

## 迁移对照

| 旧配置 | 新配置 |
| --- | --- |
| `GATEWAY_IP=172.100.0.2` | `--label docker-gateway.gateway=<gateway-name>` |
| `RULE_TAG_HK=172.100.0.10/32` | 在应用容器上使用 `--label docker-gateway.outbound=HK` |
| 手动 `docker network create ...` | 让 Docker 自动分配网关网络；如果有多个 bridge 网络，用 `docker-gateway.attach-network` 指定 |
| 网关固定 `--ip` | 不再需要，manager 会自动识别 gateway IP |

## 赞助

<a href="https://www.buymeacoffee.com/monlor" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>
