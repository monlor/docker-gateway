## 介绍

[English](/README.md) | **简体中文**

docker-gateway 项目在 Docker 之上实现了一个代理服务器网关。主要目标是为不同的容器分配不同的代理节点。其底层原理是启动一个透明代理网关服务, 将同一虚拟网络接口下其他容器的默认网关重定向到网关服务，使用 Xray 实现流量分流。

## 安装

### 初始化网关

```
# 创建网络
docker network create --subnet=172.100.0.0/24 gateway
# 运行
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

### 测试连接网关

```
docker run -d \
  --name=nginx \
  --network gateway \
  -e GATEWAY_IP=172.100.0.2 \
  --restart=unless-stopped \
  nginx
```

## 环境变量

`PORT`: 透明代理端口

`SOCKS_PORT`: 入站 Socks 端口

`RULE_TAG_*`: 网络出口到出站标签为 * 的 LAN IP 地址列表

`RULE_DOMAIN`: 默认走代理的域名列表 (默认 空)

`OUTBOUND_SERVER_*`: 创建标签 * 的出站代理服务器列表, 格式: `协议,ip:port:(user|method):pass,...`, 支持的协议: shadowsocks/http/socks

`PROXY_SERVER_TO_IP`: 解析代理服务器域名为ip (默认 true)

`NON_CN_DNS_OUT`: 非中国 DNS 服务器出站tag (默认 direct)

`CN_DNS_OUT`: 中国 DNS 服务器出站tag (默认 direct)

`CN_OUT`: 中国IP和域名出站tag (默认 direct)

`DEFAULT_OUT`: 默认出站tag

`LAN_SEGMENT`: LAN 网络段(默认 172.100.0.0/24)

## 赞助

<a href="https://www.buymeacoffee.com/monlor" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>
