#!/usr/bin/env bash

export ROOK_PROFILE_NAME=rook1
export ROOK_OBJECTSTORE_SPEC_FILE=/home/ewelder/Git/ceph-showcase/minikube/deploy/objectstore/object-multisite-test.yaml

./create-dev-cluster.sh -f -m -o