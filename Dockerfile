FROM alpine:latest

COPY --from=teddysun/xray:1.8.21 /usr/bin/xray /usr/bin

RUN apk add --no-cache ca-certificates tzdata curl iptables iptables-legacy ip6tables bash jq docker-cli
ENV TZ=Asia/Shanghai

WORKDIR /etc/xray

ENV XRAY_LOCATION_ASSET=/etc/xray

# download geoip.dat and geosite.dat 
RUN curl -#Lo /etc/xray/geoip.dat https://gh.monlor.com/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat && \
    curl -#Lo /etc/xray/geosite.dat https://gh.monlor.com/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat

COPY --chmod=755 *.sh /

ENTRYPOINT ["/entrypoint.sh"]