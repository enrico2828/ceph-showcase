#!/bin/env bash
# This script is used to bootstrap a Ceph cluster

IP=${1}

if [ -z "${IP}" ]; then
  echo "Usage: $0 <IP>"
  exit 1
fi

sudo apt update
sudo apt upgrade -y
sudo apt install -y cephadm docker.io ceph-common net-tools

cephadm bootstrap --mon-ip "${IP}" --single-host-defaults 
ceph orch apply osd --all-available-devices
ceph orch apply rgw foo

ceph dashboard set-prometheus-api-host http://"${IP}":9095
