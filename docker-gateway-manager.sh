#!/bin/bash

# confirm docker.sock
if [ ! -f /var/run/docker.sock ]; then
    echo "Error: Docker socket not found. Make sure to mount it when running the container."
    exit 0
fi

# change container gateway
modify_container_gateway() {
    container_id=$1
    gateway_ip=$2
    
    echo "Modifying gateway for container $container_id to $gateway_ip"
    
    # get netns path
    netns_path=$(docker inspect -f '{{.NetworkSettings.SandboxKey}}' "$container_id")
    
    # change default gateway
    nsenter --net="$netns_path" ip route replace default via "$gateway_ip"
}

# loop: docker events
docker events --filter 'type=container' --filter 'event=start' --format '{{.ID}}' | while read -r container_id
do
    # get container env
    gateway_ip=$(docker inspect -f '{{range .Config.Env}}{{if eq (index (split . "=") 0) "GATEWAY_IP"}}{{index (split . "=") 1}}{{end}}{{end}}' "$container_id")
    
    if [ ! -z "$gateway_ip" ]; then
        modify_container_gateway "$container_id" "$gateway_ip"
    fi
done