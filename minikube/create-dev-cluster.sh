#!/usr/bin/env bash

set -e

DEFAULT_NS="rook-ceph"
CLUSTER_FILES="common.yaml operator.yaml cluster-test.yaml cluster-on-pvc-minikube.yaml dashboard-external-http.yaml toolbox.yaml"
MONITORING_FILES="monitoring/prometheus.yaml monitoring/service-monitor.yaml monitoring/exporter-service-monitor.yaml monitoring/prometheus-service.yaml monitoring/rbac.yaml"
SCRIPT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# Script arguments: new arguments must be added here (following the same format)
export MINIKUBE_NODES="${MINIKUBE_NODES:=1}" ## Specify the minikube number of nodes to create
export MINIKUBE_DISK_SIZE="${MINIKUBE_DISK_SIZE:=40g}" ## Specify the minikube disk size
export MINIKUBE_EXTRA_DISKS="${MINIKUBE_EXTRA_DISKS:=6}" ## Specify the minikube number of extra disks
export MINIKUBE_CPUS="${MINIKUBE_CPUS:=4}" ## Specify the minikube number of cpus
export MINIKUBE_MEMORY="${MINIKUBE_MEMORY:=8G}" ## Specify the minikube memory
export ROOK_PROFILE_NAME="${ROOK_PROFILE_NAME:=rook}" ## Specify the minikube profile name
export ROOK_CLUSTER_NS="${ROOK_CLUSTER_NS:=$DEFAULT_NS}" ## CephCluster namespace
export ROOK_OPERATOR_NS="${ROOK_OPERATOR_NS:=$DEFAULT_NS}" ## Rook operator namespace (if different from CephCluster namespace)
export ROOK_EXAMPLES_DIR="${ROOK_EXAMPLES_DIR:="$SCRIPT_ROOT"/../../rook/deploy/examples}" ## Path to Rook examples directory (i.e github.com/rook/rook/deploy/examples)
export ROOK_CLUSTER_SPEC_FILE="${ROOK_CLUSTER_SPEC_FILE:=cluster-test.yaml}" ## CephCluster manifest file
export ROOK_OBJECTSTORE_SPEC_FILE="${ROOK_OBJECTSTORE_SPEC_FILE:=$SCRIPT_ROOT/deploy/objectstore/object-multisite-test.yaml}" ## CephCluster manifest file
export ROOK_OBJECTUSER_SPEC_FILE="${ROOK_OBJECTUSER_SPEC_FILE:=$SCRIPT_ROOT/deploy/objectstore/object-user.yaml}" ## CephCluster manifest file
export ROOK_OBJECTSERVICE_SPEC_FILE="${ROOK_OBJECTSERVICE_SPEC_FILE:=$SCRIPT_ROOT/deploy/objectstore/rgw-external.yaml}" ## CephCluster manifest file
export MC="${MC:=/usr/local/bin/mc}" ## mc binary for configuring S3

init_vars(){
    MINIKUBE="minikube --profile $ROOK_PROFILE_NAME"
    KUBECTL="$MINIKUBE kubectl --"

    echo "Using '$(realpath "$ROOK_EXAMPLES_DIR")' as examples directory.."
    echo "Using '$ROOK_CLUSTER_SPEC_FILE' as cluster spec file.."
    echo "Using '$ROOK_OBJECTSTORE_SPEC_FILE' as objectstore spec file.."
    echo "Using '$ROOK_PROFILE_NAME' as minikube profile.."
    echo "Using '$ROOK_CLUSTER_NS' as cluster namespace.."
    echo "Using '$ROOK_OPERATOR_NS' as operator namespace.."
}

update_namespaces() {
    if [ "$ROOK_CLUSTER_NS" != "$DEFAULT_NS" ] || [ "$ROOK_OPERATOR_NS" != "$DEFAULT_NS" ]; then
	for file in $CLUSTER_FILES $MONITORING_FILES; do
	    echo "Updating namespace on $file"
	    sed -i.bak \
		-e "s/\(.*\):.*# namespace:operator/\1: $ROOK_OPERATOR_NS # namespace:operator/g" \
		-e "s/\(.*\):.*# namespace:cluster/\1: $ROOK_CLUSTER_NS # namespace:cluster/g" \
		-e "s/\(.*serviceaccount\):.*:\(.*\) # serviceaccount:namespace:operator/\1:$ROOK_OPERATOR_NS:\2 # serviceaccount:namespace:operator/g" \
		-e "s/\(.*serviceaccount\):.*:\(.*\) # serviceaccount:namespace:cluster/\1:$ROOK_CLUSTER_NS:\2 # serviceaccount:namespace:cluster/g" \
		-e "s/\(.*\): [-_A-Za-z0-9]*\.\(.*\) # csi-provisioner-name/\1: $ROOK_OPERATOR_NS.\2 # csi-provisioner-name/g" \
		-e "s/\(.*\): [-_A-Za-z0-9]*\.\(.*\) # driver:namespace:cluster/\1: $ROOK_CLUSTER_NS.\2 # driver:namespace:cluster/g" \
		"$file"
	done
    fi
}

wait_for_ceph_cluster() {
    echo "Waiting for ceph cluster to enter HEALTH_OK"
    WAIT_CEPH_CLUSTER_RUNNING=15
    while ! $KUBECTL get cephclusters.ceph.rook.io -n "$ROOK_CLUSTER_NS" -o jsonpath='{.items[?(@.kind == "CephCluster")].status.ceph.health}' | grep -q "HEALTH_OK"; do
	echo "Waiting for Ceph cluster to enter HEALTH_OK"
	sleep ${WAIT_CEPH_CLUSTER_RUNNING}
    done
    echo "Ceph cluster installed and running"
}

wait_for_ceph_objectstore() {
    echo "Waiting for ceph objectstore to become ready"
    WAIT_CEPH_CLUSTER_RUNNING=15
    # wait for objectstore to be ready
    while ! $KUBECTL get cephobjectstores.ceph.rook.io -n "$ROOK_CLUSTER_NS" -o jsonpath='{.items[?(@.kind == "CephObjectStore")].status.phase}' | grep -q "Ready"; do
	echo "Waiting for ceph objectstore to become ready"
	sleep ${WAIT_CEPH_CLUSTER_RUNNING}
    done
    # wait for objectstore user to be ready
    OBJECTUSER=$($KUBECTL get cephobjectstoreusers.ceph.rook.io -o jsonpath='{.items[0].metadata.name}' -n "$ROOK_CLUSTER_NS")
    if [ -n "$OBJECTUSER" ]; then
        while ! $KUBECTL get cephobjectstoreusers.ceph.rook.io -n "$ROOK_CLUSTER_NS" "$OBJECTUSER" -o jsonpath='{.status.phase}' | grep -q "Ready"; do
        echo "Waiting for ceph objectstore user to become ready"
        sleep ${WAIT_CEPH_CLUSTER_RUNNING}
        done
        echo "Ceph objectstore is ready"
    fi
}

get_minikube_driver() {
    os=$(uname)
    architecture=$(uname -m)
    if [[ "$os" == "Darwin" ]]; then
        if [[ "$architecture" == "x86_64" ]]; then
            echo "hyperkit"
        elif [[ "$architecture" == "arm64" ]]; then
            echo "qemu"
        else
            echo "Unknown Architecture on Apple OS"
	    exit 1
        fi
    elif [[ "$os" == "Linux" ]]; then
        echo "kvm2"
    else
        echo "Unknown/Unsupported OS"
	exit 1
    fi
}

show_info() {
    local monitoring_enabled=$1
    local objectstore_enabled=$2
    DASHBOARD_PASSWORD=$($KUBECTL -n "$ROOK_CLUSTER_NS" get secret rook-ceph-dashboard-password -o jsonpath="{['data']['password']}" | base64 --decode && echo)
    DASHBOARD_END_POINT=$($MINIKUBE service rook-ceph-mgr-dashboard-external-http -n "$ROOK_CLUSTER_NS" --url)
    BASE_URL="$DASHBOARD_END_POINT"
    echo "==========================="
    echo "Ceph Dashboard:"
    echo "   IP_ADDR  : $BASE_URL"
    echo "   USER     : admin"
    echo "   PASSWORD : $DASHBOARD_PASSWORD"
    if [ "$monitoring_enabled" = true ]; then
	PROMETHEUS_API_HOST="http://$(kubectl -n "$ROOK_CLUSTER_NS" -o jsonpath='{.status.hostIP}' get pod prometheus-rook-prometheus-0):30900"
    echo "Prometheus Dashboard: "
    echo "   API_HOST: $PROMETHEUS_API_HOST"
    fi
    if [ "$objectstore_enabled" = true ]; then
    if [ -n "$OBJECTUSER" ]; then
        OBJECTUSERSECRET=$($KUBECTL -n "$ROOK_CLUSTER_NS" get cephobjectstoreusers.ceph.rook.io objectuser-a -o jsonpath='{.status.info.secretName}')
        S3_ACCESS_KEY=$($KUBECTL -n "$ROOK_CLUSTER_NS" get secret "$OBJECTUSERSECRET" -o jsonpath="{['data']['AccessKey']}" | base64 --decode && echo)
        S3_SECRET_KEY=$($KUBECTL -n "$ROOK_CLUSTER_NS" get secret "$OBJECTUSERSECRET" -o jsonpath="{['data']['SecretKey']}" | base64 --decode && echo)
    fi
    S3_END_POINT=$($MINIKUBE service rook-ceph-rgw-objectstore-external -n "$ROOK_CLUSTER_NS" --url)
    echo "Obect Gateway S3 Endpoint: "
    echo "   S3 Endpoint: $S3_END_POINT"
    echo "   AccessKey  : $S3_ACCESS_KEY"
    echo "   SecretKey  : $S3_SECRET_KEY"
    echo "Configuring Minio mc client ..."
    $MC alias set "$ROOK_PROFILE_NAME" "$S3_END_POINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY"
    fi
    echo "==========================="
    echo " "
    echo " *** To start using your rook cluster please set the following env: "
    echo " "
    echo "   > eval \$($MINIKUBE docker-env)"
    echo "   > alias kubectl=\"$KUBECTL"\"
    echo " "
    echo " *** To access the new cluster with k9s: "
    echo " "
    echo "   > k9s --context $ROOK_PROFILE_NAME"
    echo " "
}

check_minikube_exists() {
    echo "Checking minikube profile '$ROOK_PROFILE_NAME'..."
    if minikube profile list -l 2> /dev/null | grep -qE "\s$ROOK_PROFILE_NAME\s"; then
        echo "A minikube profile '$ROOK_PROFILE_NAME' already exists, please use -f to force the cluster creation."
	exit 1
    fi
}

setup_minikube_env() {
    minikube_driver="$(get_minikube_driver)"
    echo "Setting up minikube env for profile '$ROOK_PROFILE_NAME' (using $minikube_driver driver)"
    $MINIKUBE delete || error "Error deleting exsiting Minikube instance"
    $MINIKUBE start --disk-size="$MINIKUBE_DISK_SIZE" --extra-disks="$MINIKUBE_EXTRA_DISKS" --driver "$minikube_driver" -n "$MINIKUBE_NODES" --cpus "$MINIKUBE_CPUS" --memory "$MINIKUBE_MEMORY"  --network rook || error "Error starting Minikube"
    eval "$($MINIKUBE docker-env)"
}

create_rook_cluster() {
    echo "Creating cluster"
    # create operator namespace if it doesn't exist
    if ! kubectl get namespace "$ROOK_OPERATOR_NS" &> /dev/null; then
	kubectl create namespace "$ROOK_OPERATOR_NS"
    fi
    $KUBECTL apply -f crds.yaml -f common.yaml -f operator.yaml
    $KUBECTL apply -f "$ROOK_CLUSTER_SPEC_FILE" -f toolbox.yaml
    $KUBECTL apply -f dashboard-external-http.yaml
    CEPHCLUSTER=$($KUBECTL get cephclusters.ceph.rook.io -o jsonpath='{.items[*].metadata.name}' -n "$ROOK_OPERATOR_NS")
}

change_to_examples_dir() {
    if [ ! -e "$ROOK_EXAMPLES_DIR" ]; then
	echo "Examples directory '$ROOK_EXAMPLES_DIR' does not exist. Please, provide a valid rook examples directory."
	exit 1
    fi

    CRDS_FILE_PATH=$(realpath "$ROOK_EXAMPLES_DIR/crds.yaml")
    if [ ! -e "$CRDS_FILE_PATH" ]; then
	echo "File '$CRDS_FILE_PATH' does not exist. Please, provide a valid rook examples directory."
	exit 1
    fi

    ROOK_CLUSTER_SPEC_PATH=$(realpath "$ROOK_EXAMPLES_DIR/$ROOK_CLUSTER_SPEC_FILE")
    if [ ! -e "$ROOK_CLUSTER_SPEC_PATH" ]; then
	echo "File '$ROOK_CLUSTER_SPEC_PATH' does not exist. Please, provide a valid cluster spec file."
	exit 1
    fi

    cd "$ROOK_EXAMPLES_DIR" || exit
}

wait_for_rook_operator() {
    echo "Waiting for rook operator..."
    $KUBECTL rollout status deployment rook-ceph-operator -n "$ROOK_OPERATOR_NS" --timeout=180s
    while ! $KUBECTL get cephclusters.ceph.rook.io -n "$ROOK_CLUSTER_NS" -o jsonpath='{.items[?(@.kind == "CephCluster")].status.phase}' | grep -q "Ready"; do
	echo "Waiting for ceph cluster to become ready..."
	sleep 20
    done
}

enable_rook_orchestrator() {
    echo "Enabling rook orchestrator"
    $KUBECTL rollout status deployment rook-ceph-tools -n "$ROOK_CLUSTER_NS" --timeout=90s
    $KUBECTL -n "$ROOK_CLUSTER_NS" exec -it deploy/rook-ceph-tools -- ceph mgr module enable rook
    $KUBECTL -n "$ROOK_CLUSTER_NS" exec -it deploy/rook-ceph-tools -- ceph orch set backend rook
    $KUBECTL -n "$ROOK_CLUSTER_NS" exec -it deploy/rook-ceph-tools -- ceph orch status
}

enable_monitoring() {
    echo "Enabling monitoring"
    $KUBECTL create -f https://raw.githubusercontent.com/coreos/prometheus-operator/v0.73.1/bundle.yaml
    $KUBECTL wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus-operator --timeout=30s -n default
    $KUBECTL apply -f monitoring/rbac.yaml
    $KUBECTL apply -f monitoring/service-monitor.yaml
    $KUBECTL apply -f monitoring/exporter-service-monitor.yaml
    $KUBECTL apply -f monitoring/prometheus.yaml
    $KUBECTL apply -f monitoring/prometheus-service.yaml
    $KUBECTL wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus --timeout=180s -n "$ROOK_CLUSTER_NS"
    PROMETHEUS_API_HOST="http://$(kubectl -n "$ROOK_CLUSTER_NS" -o jsonpath='{.status.hostIP}' get pod prometheus-rook-prometheus-0):30900"
    $KUBECTL -n "$ROOK_CLUSTER_NS" exec -it deploy/rook-ceph-tools -- ceph dashboard set-prometheus-api-host "$PROMETHEUS_API_HOST"
    #$KUBECTL patch cephclusters.ceph.rook.io -n "$ROOK_CLUSTER_NS" "$CEPHCLUSTER" --type merge --patch-file "$SCRIPT_ROOT/deploy/monitoring/cephcluster-prometheus-patch.yaml"
}

enable_objectstore() {
    echo "Enabling object store"
    $KUBECTL apply -f "$ROOK_OBJECTSTORE_SPEC_FILE"
}

show_usage() {
    echo ""
    echo "Usage: [ARG=VALUE]... $(basename "$0") [-f] [-r] [-m] [o]"
    echo "  -f     Force cluster creation by deleting minikube profile"
    echo "  -r     Enable rook orchestrator"
    echo "  -m     Enable monitoring"
    echo "  -o     Enable object store"
    echo "  -m     Enable monitoring"
    echo "  Args:"
    sed -n -E "s/^export (.*)=\".*:=.*\" ## (.*)/    \1 (\\$\1):  \2/p;" "$SCRIPT_ROOT"/"$(basename "$0")" | envsubst
    echo ""
}

invocation_error() {
    printf "%s\n" "$*" > /dev/stderr
    show_usage
    exit 1
}

####################################################################
################# MAIN #############################################

while getopts "hrmfo" opt; do
    case $opt in
        h)
            show_usage
            exit 0
            ;;
        r)
            enable_rook=true
            ;;
        m)
            enable_monitoring=true
            ;;
        f)
            force_minikube=true
            ;;
        o)
            enable_objectstore=true
            ;;
        \?)
            invocation_error "Invalid option: -$OPTARG"
            ;;
        :)
            invocation_error "Option -$OPTARG requires an argument."
            ;;
    esac
done

# initialization zone
init_vars
change_to_examples_dir
[ -z "$force_minikube" ] && check_minikube_exists
update_namespaces

# cluster creation zone
setup_minikube_env
create_rook_cluster
wait_for_rook_operator
wait_for_ceph_cluster

# final tweaks and ceph cluster tuning
[ "$enable_rook" = true ] && enable_rook_orchestrator
[ "$enable_monitoring" = true ] && enable_monitoring
[ "$enable_objectstore" = true ] && enable_objectstore && wait_for_ceph_objectstore
show_info "$enable_monitoring" "$enable_objectstore"

####################################################################
####################################################################
