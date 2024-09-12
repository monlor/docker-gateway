#!/bin/bash

# confirm docker.sock
if [ ! -S /var/run/docker.sock ]; then
    echo "Error: Docker socket not found. Make sure to mount it when running the container."
    exit 0
fi

# 检查容器健康状态，最多检测5次
check_container_health() {
    container_id=$1
    max_checks=3
    interval=2

    check_count=0

    while [ $check_count -lt $max_checks ]; do
        health_status=$(docker inspect --format='{{.State.Status}}' "$container_id")
        exit_code=$(docker inspect --format='{{.State.ExitCode}}' "$container_id")
        if [ "$health_status" = "running" ]; then
            echo "Container $container_id is healthy."
            return 0
        elif [ "exit_code" != "0" ]; then
            echo "Container $container_id is not healthy. Exit code: $exit_code"
            return 1
        else
            echo "Container $container_id is not healthy. Current status: $health_status"
        fi
        
        check_count=$((check_count + 1))
        echo "Waiting for container $container_id to become healthy... Attempt $check_count of $max_checks"
        sleep ${interval}
    done

    echo "Reached maximum health check attempts for container $container_id."
    return 1
}

# 修改 modify_container_gateway 函数以使用新的 check_container_health 函数
modify_container_gateway() {
    container_id=$1
    gateway_ip=$2

    echo "Attempting to modify gateway for container $container_id to $gateway_ip"
    
    # 使用 check_container_health 函数检查容器健康状态
    if ! check_container_health "$container_id"; then
        echo "Skipping gateway modification due to container health check failure."
        return
    fi
    
    # 修改容器网关的逻辑...
    nsenter -t "$(docker inspect -f '{{.State.Pid}}' "$container_id")" -n ip route replace default via "$gateway_ip"
    echo "Gateway modified for container $container_id."
}

# 新增函数：扫描并修改所有运行中的容器网关
scan_and_modify_gateways() {
    # 获取所有运行中的容器ID
    container_ids=$(docker ps -q)
    for container_id in $container_ids; do
        # 获取容器环境变量中的GATEWAY_IP
        gateway_ip=$(docker inspect -f '{{range .Config.Env}}{{if eq (index (split . "=") 0) "GATEWAY_IP"}}{{index (split . "=") 1}}{{end}}{{end}}' "$container_id")
        
        # 如果GATEWAY_IP存在，则修改容器网关
        if [ ! -z "$gateway_ip" ]; then
            modify_container_gateway "$container_id" "$gateway_ip"
        fi
    done
}

# 在监听事件之前，扫描并修改所有运行中的容器网关
scan_and_modify_gateways

# loop: docker events
echo "Listening for container events..."
docker events --filter 'type=container' --filter 'event=start' --filter 'event=restart' --format '{{.ID}}' | while read -r container_id
do
    # get container env
    gateway_ip=$(docker inspect -f '{{range .Config.Env}}{{if eq (index (split . "=") 0) "GATEWAY_IP"}}{{index (split . "=") 1}}{{end}}{{end}}' "$container_id")
    
    if [ ! -z "$gateway_ip" ]; then
        modify_container_gateway "$container_id" "$gateway_ip"
    fi
done