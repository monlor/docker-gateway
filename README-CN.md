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
  --label docker-gateway.allow-attach=true \
  --label docker-gateway.proxy=socks,1.1.1.1:2222:user:pass \
  --label docker-gateway.dns-servers=8.8.8.8 \
  --label docker-gateway.dns-mode=direct \
  --restart=unless-stopped \
  nginx
```

应用容器不再需要配置网关 IP。manager 会自动识别 gateway 的 IP。如果应用容器当前不在 gateway 管理的网络上，需要添加 `docker-gateway.allow-attach=true`，或者在 gateway 容器上设置 `AUTO_ATTACH_CONTAINERS=true`。

## 容器 Label

`docker-gateway.name`: 网关容器必填，表示逻辑网关名

`docker-gateway.attach-network`: 网关容器可选；仅在网关加入多个 bridge 网络时需要指定

`docker-gateway.gateway`: 应用容器必填，指向目标网关逻辑名

`docker-gateway.allow-attach`: 应用容器可选；设置为 `true` 时允许 gateway 按需把这个容器接入受管 bridge 网络

`docker-gateway.proxy`: 应用容器可选
`http` 或 `socks` 格式：`protocol,host:port[:user][:pass][,host:port[:user][:pass],...]`
`shadowsocks` 格式：`shadowsocks,host:port:method:password[,host:port:method:password,...]`

`docker-gateway.dns-servers`: 应用容器可选；单个 IPv4 DNS 服务器地址，例如 `8.8.8.8`

`docker-gateway.dns-mode`: 应用容器可选；`direct` 或 `proxy`，当设置 `docker-gateway.dns-servers` 且未指定时默认 `direct`。如果与 `http` 代理一起使用 `proxy`，gateway 会记录兼容性警告，因为普通 UDP/53 DNS 查询可能无法通过 HTTP 出站。

## 环境变量

`PORT`: 透明代理端口

`SOCKS_PORT`: 入站 Socks 端口

`RULE_DOMAIN`: 附加到代理 label 动态路由上的域名列表 (默认 空)

`PROXY_SERVER_TO_IP`: 解析代理服务器域名为ip (默认 true)

`AUTO_ATTACH_CONTAINERS`: 允许 gateway 无需 `docker-gateway.allow-attach=true` 也自动把匹配容器接入受管 bridge 网络 (默认 false)

`STRICT_LABELS`: 遇到非法代理或 DNS label 时直接让本次同步失败，而不是静默跳过 (默认 false)

`IPTABLES_COMMAND`: 指定 gateway 使用的 iptables 二进制；如果不设置，会按 `iptables`、`iptables-legacy`、`iptables-nft` 的顺序自动探测

`LOG_LEVEL`: Gateway 和 Xray 的日志级别。`info` 保留运维相关日志，但关闭逐请求 access log 和 DNS 查询日志；`debug` 打开更详细的 Xray access/DNS 日志；`warning`、`error`、`none` 会逐步减少 shell 日志输出 (默认 info)

`CN_OUT`: 中国IP和域名出站tag (默认 direct)

`DEFAULT_OUT`: 默认出站tag

`XRAY_API_PORT`: 本地 Xray RoutingService 端口 (默认 10085)

## 运行时要求

镜像内的 `xray` CLI 需要支持：

* `RoutingService`
* `HandlerService`
* `xray api adrules`
* `xray api rmrules`
* `xray api ado`
* `xray api rmo`

gateway manager 还依赖：

* `bash`
* `jq`
* `docker`
* `ip`
* `nsenter`
* 一个可用的 iptables 二进制 (`iptables`、`iptables-legacy` 或 `iptables-nft`)

## Manager 模式

manager 现在支持一次性同步和面向 agent 的状态查看模式：

* `/docker-gateway-manager.sh --sync-once`：执行一次同步，并输出最新同步结果 JSON
* `/docker-gateway-manager.sh --print-desired-state`：不修改容器和 Xray，只输出期望状态 JSON
* `/docker-gateway-manager.sh --status`：输出最近一次同步结果 JSON

## Label 示例

* 为应用容器设置 socks5 代理

```
--label docker-gateway.proxy=socks,1.1.1.1:2222:user:pass
```

* 为应用容器设置 shadowsocks 代理，并让 DNS 直连到 `8.8.8.8`

```bash
docker run -d \
  --name=nginx \
  --label docker-gateway.gateway=main \
  --label docker-gateway.allow-attach=true \
  --label docker-gateway.proxy=shadowsocks,1.1.1.1:8388:aes-256-gcm:password \
  --label docker-gateway.dns-servers=8.8.8.8 \
  --label docker-gateway.dns-mode=direct \
  --restart=unless-stopped \
  nginx
```

## 迁移对照

| 旧配置 | 新配置 |
| --- | --- |
| `GATEWAY_IP=172.100.0.2` | `--label docker-gateway.gateway=<gateway-name>` |
| `OUTBOUND_SERVER_HK=socks,1.1.1.1:2222:user:pass` | 在应用容器上使用 `--label docker-gateway.proxy=socks,1.1.1.1:2222:user:pass` |
| `RULE_TAG_HK=172.100.0.10/32` | 已移除，应用代理路由由 `docker-gateway.proxy` 决定 |
| `NON_CN_DNS_OUT` / `CN_DNS_OUT` | `--label docker-gateway.dns-servers=<ipv4>` 加 `--label docker-gateway.dns-mode=direct|proxy` |
| 默认自动把应用容器接入 gateway 网络 | 在应用容器上加 `--label docker-gateway.allow-attach=true`，或在 gateway 上设置 `AUTO_ATTACH_CONTAINERS=true` |
| 手动 `docker network create ...` | 让 Docker 自动分配网关网络；如果有多个 bridge 网络，用 `docker-gateway.attach-network` 指定 |
| 网关固定 `--ip` | 不再需要，manager 会自动识别 gateway IP |

## 赞助

<a href="https://www.buymeacoffee.com/monlor" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>
