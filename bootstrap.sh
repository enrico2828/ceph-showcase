
#!/bin/env bash
# This script is used to bootstrap a Ceph cluster

sudo apt update
sudo apt upgrade -y
sudo apt install -y cephadm docker.io ceph-common net-tools

cephadm bootstrap --mon-ip 192.168.50.10 --single-host-defaults 
ceph orch apply osd --all-available-devices
ceph orch apply rgw foo