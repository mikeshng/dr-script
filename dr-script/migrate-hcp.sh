#!/bin/bash

set -eux

commands=("aws" "oc" "ocm" "rosa" "yq")
for cmd in "${commands[@]}"
do
    echo "Checking to see if $cmd command is available..."
    command -v $cmd
done

function get_hc_kubeconfig() {
    if [ ! -f ${HC_KUBECONFIG} ]; then
        touch ${HC_KUBECONFIG}
    fi
    export KUBECONFIG=${HC_KUBECONFIG}

    # Don't exit if login failed, takes time for control plane to come up on restore
    set +e 
    attempts=$1
    for i in $(seq 1 $attempts); do
        ${OC} login $(rosa describe cluster -c ${HC_CLUSTER_ID} -o json | jq -r .api.url) -u kubeadmin -p ${HC_PASS}
        if [ $? -eq 0 ]; then
            break
        fi

        sleep 3
    done
    set -e
}

function get_hc_kubeadmin_pass() {
  export KUBECONFIG="${MGMT_KUBECONFIG}"

  HC_PASS=$(${OC} get secret -n  ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} kubeadmin-password -ojsonpath='{.data.password}' | base64 -d)
}

function create_cm_in_hc() {
    get_hc_kubeconfig 1

    # Create a ConfigMap on the guest so we can tell which management cluster it came from
    export KUBECONFIG=${HC_KUBECONFIG}

    # HC may be in failed state. Do not fail backup if access to HC fails
    set +e 
    ${OC} create configmap ${USER}-dev-cluster -n default --from-literal=from=${MGMT_CLUSTER_NAME} || true
    if [ $? -ne 0 ]; then
        echo "Failed to create ConfigMap on Hosted Cluster."
    fi
    set -e
}

function change_reconciliation() {

    if [[ -z "${1}" ]];then
        echo "Give me the status <start|stop>"
        exit 1
    fi

    case ${1} in
        "stop")
            export KUBECONFIG=${MGMT_KUBECONFIG}
            # Pause reconciliation of HC and NP and ETCD writers
            PAUSED_UNTIL="true"
            ${OC} patch -n ${HC_CLUSTER_NS} hostedclusters/${HC_CLUSTER_NAME} -p '{"spec":{"pausedUntil":"'${PAUSED_UNTIL}'"}}' --type=merge
            for nodepool in ${NODEPOOLS}
            do
                ${OC} patch -n ${HC_CLUSTER_NS} nodepools/${nodepool} -p '{"spec":{"pausedUntil":"'${PAUSED_UNTIL}'"}}' --type=merge
            done
            ${OC} scale deployment -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=0 kube-apiserver openshift-apiserver openshift-oauth-apiserver control-plane-operator
            ;;
        "start")
            # Restart reconciliation of HC and NP and ETCD writers
            PAUSED_UNTIL="false"
            ${OC} patch -n ${HC_CLUSTER_NS} hostedclusters/${HC_CLUSTER_NAME} -p '{"spec":{"pausedUntil":"'${PAUSED_UNTIL}'"}}' --type=merge
            for nodepool in ${NODEPOOLS}
            do
                ${OC} patch -n ${HC_CLUSTER_NS} nodepools/${nodepool} -p '{"spec":{"pausedUntil":"'${PAUSED_UNTIL}'"}}' --type=merge
            done
            ${OC} scale deployment -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=1 kube-apiserver openshift-apiserver openshift-oauth-apiserver control-plane-operator
            ;;
        *)
            echo "Status not implemented"
            exit 1
            ;;
    esac

}

function backup_etcd() {
    # ETCD Backup
    POD="etcd-0"
    ETCD_CA_LOCATION=/etc/etcd/tls/etcd-ca/ca.crt

    # Create an etcd snapshot
    ${OC} exec -it ${POD} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -- env ETCDCTL_API=3 /usr/bin/etcdctl --cacert ${ETCD_CA_LOCATION} --cert /etc/etcd/tls/client/etcd-client.crt --key /etc/etcd/tls/client/etcd-client.key --endpoints=localhost:2379 snapshot save /var/lib/data/snapshot.db

    ${OC} exec -it ${POD} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -- env ETCDCTL_API=3 /usr/bin/etcdctl -w table snapshot status /var/lib/data/snapshot.db

    FILEPATH="/${BUCKET_NAME}/${HC_CLUSTER_NAME}-${POD}-snapshot.db"
    CONTENT_TYPE="application/x-compressed-tar"
    DATE_VALUE=`date -R`
    SIGNATURE_STRING="PUT\n\n${CONTENT_TYPE}\n${DATE_VALUE}\n${FILEPATH}"

    ACCESS_KEY=$(grep aws_access_key_id ${AWS_CREDS} | head -n1 | cut -d= -f2 | sed "s/ //g")
    SECRET_KEY=$(grep aws_secret_access_key ${AWS_CREDS} | head -n1 | cut -d= -f2 | sed "s/ //g")
    SIGNATURE_HASH=$(echo -en ${SIGNATURE_STRING} | openssl sha1 -hmac "${SECRET_KEY}" -binary | base64)

    ${OC} exec -it etcd-0 -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -- curl -X PUT -T "/var/lib/data/snapshot.db" \
      -H "Host: ${BUCKET_NAME}.s3.amazonaws.com" \
      -H "Date: ${DATE_VALUE}" \
      -H "Content-Type: ${CONTENT_TYPE}" \
      -H "Authorization: AWS ${ACCESS_KEY}:${SIGNATURE_HASH}" \
      https://${BUCKET_NAME}.s3.amazonaws.com/${HC_CLUSTER_NAME}-${POD}-snapshot.db

    echo "Checking to see if the backup uploaded successfully to s3..."
    aws s3 ls s3://${BUCKET_NAME}/${HC_CLUSTER_NAME}-${POD}-snapshot.db
}

function render_hc_objects {
    # Backup resources
    mkdir -p ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS} ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    chmod 700 ${BACKUP_DIR}/namespaces/

    export KUBECONFIG="${MGMT_KUBECONFIG}"

    # Certificates
    echo "Backing Up Certificate Objects:"
    ${OC} get certificate cluster-api-cert -n ${HC_CLUSTER_NS} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/certificate-cluster-api-cert.yaml
    echo "--> Certificate"
    # sed -i'' -e '/^status:$/,$d' ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}.yaml

    # HostedCluster
    echo "Backing Up HostedCluster Objects:"
    ${OC} get hc ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}.yaml
    echo "--> HostedCluster"
    sed -i'' -e '/^status:$/,$d' ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}.yaml

    # NodePool
    for nodepool in ${NODEPOOLS}
    do
        ${OC} get np ${nodepool} -n ${HC_CLUSTER_NS} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/np-${nodepool}.yaml
        echo "--> NodePool ${nodepool}"
        sed -i'' -e '/^status:$/,$ d' ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/np-${nodepool}.yaml
    done

    # Secrets in the HC Namespace
    echo "--> HostedCluster Secrets"
    for s in $(${OC} get secret -n ${HC_CLUSTER_NS}  | grep "^${HC_CLUSTER_NAME}" | awk '{print $1}'); do
        ${OC} get secret -n ${HC_CLUSTER_NS} $s -o yaml  > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/secret-${s}.yaml
    done

    echo "--> HostedCluster Secrets"
    for s in $(${OC} get secret -n ${HC_CLUSTER_NS}  | grep bound | awk '{print $1}'); do
        ${OC} get secret -n ${HC_CLUSTER_NS} $s -o yaml  > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/secret-${s}.yaml
    done
    for s in $(${OC} get secret -n ${HC_CLUSTER_NS}  | grep htpasswd-secret | awk '{print $1}'); do
        ${OC} get secret -n ${HC_CLUSTER_NS} $s -o yaml  > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/secret-${s}.yaml
    done

    # Secrets in the HC Control Plane Namespace
    echo "--> HostedCluster ControlPlane Secrets"
    for s in $(${OC} get secret -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}  | egrep -v "docker|service-account-token|oauth-openshift|NAME|token-${HC_CLUSTER_NAME}" | awk '{print $1}'); do
        ${OC} get secret  -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/secret-${s}.yaml
    done

    # Hosted Control Plane
    echo "--> HostedControlPlane"
    ${OC} get hcp ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/hcp-${HC_CLUSTER_NAME}.yaml

    # Cluster
    echo "--> Cluster"
    CL_NAME=$(${OC} get hcp ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o jsonpath={.metadata.labels.\*})
    ${OC} get cluster ${CL_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/cl-${HC_CLUSTER_NAME}.yaml

    # AWS Cluster
    echo "--> AWS Cluster"
    ${OC} get awscluster ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/awscl-${HC_CLUSTER_NAME}.yaml

    # AWS MachineTemplate
    echo "--> AWS Machine Template"
    MT_NAME=$(${OC} get awsmachinetemplate -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o json | jq -r '.items[0].metadata.name')
    ${OC} get awsmachinetemplate ${MT_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/awsmt-${HC_CLUSTER_NAME}.yaml

    # AWS Machines
    echo "--> AWS Machine"
    CL_NAME=$(${OC} get hcp ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o jsonpath={.metadata.labels.\*})
    for s in $(${OC} get awsmachines -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --no-headers | grep ${CL_NAME} | cut -f 1 -d\ ); do
        ${OC} get -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} awsmachines $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/awsm-${s}.yaml
    done

    # MachineDeployments
    echo "--> HostedCluster MachineDeployments"
    for s in $(${OC} get machinedeployment -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name); do
        mdp_name=$(echo ${s} | cut -f 2 -d /)
        ${OC} get -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/machinedeployment-${mdp_name}.yaml
    done

    # MachineSets
    echo "--> HostedCluster MachineSets"
    for s in $(${OC} get machineset.cluster.x-k8s.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name); do
        ms_name=$(echo ${s} | cut -f 2 -d /)
        ${OC} get -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/machineset-${ms_name}.yaml
    done

    # Machines
    echo "--> HostedCluster Machines"
    for s in $(${OC} get machine.cluster.x-k8s.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name); do
        m_name=$(echo ${s} | cut -f 2 -d /)
        ${OC} get -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/machine-${m_name}.yaml
    done
}

function restore_etcd() {

    ETCD_PODS="etcd-0"
    if [ "${CONTROL_PLANE_AVAILABILITY_POLICY}" = "HighlyAvailable" ]; then
      ETCD_PODS="etcd-0 etcd-1 etcd-2"
    fi
    
    HC_RESTORE_FILE=${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}-restore.yaml
    HC_BACKUP_FILE=${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}.yaml
    HC_NEW_FILE=${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}-new.yaml
    cat ${HC_BACKUP_FILE} > ${HC_NEW_FILE}
    cat > ${HC_RESTORE_FILE} <<EOF
        restoreSnapshotURL:
EOF

    for POD in ${ETCD_PODS}; do
      # Create a pre-signed URL for the etcd snapshot
      ETCD_SNAPSHOT="s3://${BUCKET_NAME}/${HC_CLUSTER_NAME}-etcd-0-snapshot.db"
      ETCD_SNAPSHOT_URL=$(AWS_DEFAULT_REGION=${MGMT2_REGION} aws s3 presign ${ETCD_SNAPSHOT})

      # FIXME no CLI support for restoreSnapshotURL yet
      cat >> ${HC_RESTORE_FILE} <<EOF
        - "${ETCD_SNAPSHOT_URL}"
EOF
    done

    cat ${HC_RESTORE_FILE}

    if ! grep ${HC_CLUSTER_NAME}-snapshot.db ${HC_NEW_FILE}; then
      sed -i'' -e "/type: PersistentVolume/r ${HC_RESTORE_FILE}" ${HC_NEW_FILE}
      sed -i'' -e '/pausedUntil:/d' ${HC_NEW_FILE}
    fi

    HC=$(${OC} get hc -n ${HC_CLUSTER_NS} ${HC_CLUSTER_NAME} -o name || true)
    if [[ ${HC} == "" ]];then
        echo "Deploying HC Cluster: ${HC_CLUSTER_NAME} in ${HC_CLUSTER_NS} namespace"
        ${OC} apply -f ${HC_NEW_FILE}
    else
        echo "HC Cluster ${HC_CLUSTER_NAME} already exists, avoiding step"
    fi

}

function restore_object() {
    if [[ -z ${1} || ${1} == " " ]]; then
        echo "I need an argument to deploy K8s objects"
        exit 1
    fi

    if [[ -z ${2} || ${2} == " " ]]; then
        echo "I need a Namespace to deploy the K8s objects"
        exit 1
    fi

    if [[ ! -d ${BACKUP_DIR}/namespaces/${2} ]];then
        echo "folder: ${BACKUP_DIR}/namespaces/${2} does not exists"
        exit 1
    fi

    case ${1} in
        "secret" | "machine" | "machineset" | "hcp" | "cl" | "awscl" | "awsmt" | "awsm" | "machinedeployment")
            # Cleaning the YAML files before apply them
            for f in $(ls -1 ${BACKUP_DIR}/namespaces/${2}/${1}-*); do
                yq eval 'del(.metadata.ownerReferences,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.status)' $f | ${OC} apply -f -
            done
            ;;
        "certificate")
            for f in $(ls -1 ${BACKUP_DIR}/namespaces/${2}/${1}-*); do
                yq eval 'del(.metadata.ownerReferences,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.status)' $f | ${OC} apply -f -
            done
            ;;
        "hc")
            # Cleaning the YAML files before apply them
            for f in $(ls -1 ${BACKUP_DIR}/namespaces/${2}/${1}-*); do
                yq eval 'del(.metadata.ownerReferences,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.status,.spec.pausedUntil)' $f | ${OC} apply -f -
            done
            ;;
        "np")
            # Cleaning the YAML files before apply them
            for f in $(ls -1 ${BACKUP_DIR}/namespaces/${2}/${1}-*); do
                yq eval 'del(.metadata.annotations,.metadata.ownerReferences,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.status,.spec.pausedUntil)' $f | ${OC} apply -f -
            done
            ;;
        *)
            echo "K8s object not supported: ${1}"
            exit 1
            ;;
    esac

}

function clean_routes() {

    if [[ -z "${1}" ]];then
        echo "Give me the NS where to clean the routes"
        exit 1
    fi

    ${OC} delete route -n ${1} --all
}

function render_svc_objects() {
    BACKUP_DIR=${HC_CLUSTER_DIR}/backup
    mkdir -p ${BACKUP_DIR}/svc
    # Change kubeconfig to service cluster
    export KUBECONFIG="${SVC_KUBECONFIG}"

    # ManagedCluster
    echo "Backing Up HostedCluster Objects:"
    ${OC} get managedcluster ${HC_CLUSTER_ID} -o yaml > ${BACKUP_DIR}/svc/managedcluster-${HC_CLUSTER_ID}.yaml
    echo "--> ManagedCluster"
    sed -i'' -e '/^status:$/,$d' ${BACKUP_DIR}/svc/managedcluster-${HC_CLUSTER_ID}.yaml
    sed -i'' -e "s/${MGMT_CLUSTER_NAME}/${MGMT2_CLUSTER_NAME}/g" ${BACKUP_DIR}/svc/managedcluster-${HC_CLUSTER_ID}.yaml

    # ManagedClusterAddOns
    ${OC} get managedclusteraddons -n ${HC_CLUSTER_ID} config-policy-controller -o yaml > ${BACKUP_DIR}/svc/managedclusteraddon-config-policy-controller-${HC_CLUSTER_ID}.yaml
    echo "--> config-policy-controller ManagedClusterAddOn"
    sed -i'' -e '/^status:$/,$d' ${BACKUP_DIR}/svc/managedclusteraddon-config-policy-controller-${HC_CLUSTER_ID}.yaml
    sed -i'' -e "s/${MGMT_CLUSTER_NAME}/${MGMT2_CLUSTER_NAME}/g" ${BACKUP_DIR}/svc/managedclusteraddon-config-policy-controller-${HC_CLUSTER_ID}.yaml

    ${OC} get managedclusteraddons -n ${HC_CLUSTER_ID} governance-policy-framework -o yaml > ${BACKUP_DIR}/svc/managedclusteraddon-governance-policy-framework-${HC_CLUSTER_ID}.yaml
    echo "--> governance-policy-framework ManagedClusterAddOn"
    sed -i'' -e '/^status:$/,$d' ${BACKUP_DIR}/svc/managedclusteraddon-governance-policy-framework-${HC_CLUSTER_ID}.yaml
    sed -i'' -e "s/${MGMT_CLUSTER_NAME}/${MGMT2_CLUSTER_NAME}/g" ${BACKUP_DIR}/svc/managedclusteraddon-governance-policy-framework-${HC_CLUSTER_ID}.yaml

    ${OC} get managedclusteraddons -n ${HC_CLUSTER_ID} work-manager -o yaml > ${BACKUP_DIR}/svc/managedclusteraddon-work-manager-${HC_CLUSTER_ID}.yaml
    echo "--> work-manager ManagedClusterAddOn"
    sed -i'' -e '/^status:$/,$d' ${BACKUP_DIR}/svc/managedclusteraddon-work-manager-${HC_CLUSTER_ID}.yaml
    sed -i'' -e "s/${MGMT_CLUSTER_NAME}/${MGMT2_CLUSTER_NAME}/g" ${BACKUP_DIR}/svc/managedclusteraddon-work-manager-${HC_CLUSTER_ID}.yaml

    # ManifestWork
    ${OC} get manifestwork -n ${MGMT_CLUSTER_NAME} ${HC_CLUSTER_ID} -o yaml > ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}.yaml
    echo "--> ${HC_CLUSTER_ID} ManifestWork"
    sed -i'' -e '/^status:$/,$d' ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}.yaml
    sed -i'' -e "s/${MGMT_CLUSTER_NAME}/${MGMT2_CLUSTER_NAME}/g" ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}.yaml
    ${OC} patch manifestwork -n ${MGMT_CLUSTER_NAME} ${HC_CLUSTER_ID} --type=merge --patch '{"spec":{"deleteOption":{"propagationPolicy":"Orphan"}}}'

    ${OC} get manifestwork -n ${MGMT_CLUSTER_NAME} ${HC_CLUSTER_ID}-00-namespaces -o yaml > ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}-00-namespaces.yaml
    echo "--> ${HC_CLUSTER_ID}-00-namespaces ManifestWork"
    sed -i'' -e '/^status:$/,$d' ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}-00-namespaces.yaml
    sed -i'' -e "s/${MGMT_CLUSTER_NAME}/${MGMT2_CLUSTER_NAME}/g" ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}-00-namespaces.yaml
    ${OC} patch manifestwork -n ${MGMT_CLUSTER_NAME} ${HC_CLUSTER_ID}-00-namespaces --type=merge --patch '{"spec":{"deleteOption":{"propagationPolicy":"Orphan"}}}'

    ${OC} get manifestwork -n ${MGMT_CLUSTER_NAME} ${HC_CLUSTER_ID}-workers -o yaml > ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}-workers.yaml
    echo "--> ${HC_CLUSTER_ID}-workers ManifestWork"
    sed -i'' -e '/^status:$/,$d' ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}-workers.yaml
    sed -i'' -e "s/${MGMT_CLUSTER_NAME}/${MGMT2_CLUSTER_NAME}/g" ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}-workers.yaml
    ${OC} patch manifestwork -n ${MGMT_CLUSTER_NAME} ${HC_CLUSTER_ID}-workers --type=merge --patch '{"spec":{"deleteOption":{"propagationPolicy":"Orphan"}}}'

    # This will be recreated upon updating the managedcluster so we don't back it up
    ${OC} patch manifestwork -n ${MGMT_CLUSTER_NAME} ${HC_CLUSTER_ID}-hosted-klusterlet --type=merge --patch '{"spec":{"deleteOption":{"propagationPolicy":"Orphan"}}}'

    ${OC} delete manifestwork -n ${MGMT_CLUSTER_NAME} ${HC_CLUSTER_ID} ${HC_CLUSTER_ID}-00-namespaces ${HC_CLUSTER_ID}-workers
}

function backup_hc() {
    BACKUP_DIR=${HC_CLUSTER_DIR}/backup
                
    if [ -d ${BACKUP_DIR} ]; then
        echo "There is an existing backup in ${BACKUP_DIR}. Remove it before starting a new backup."
        exit 1          
    fi

    mkdir -p ${BACKUP_DIR}
    create_cm_in_hc

    # Change kubeconfig to management cluster
    export KUBECONFIG="${MGMT_KUBECONFIG}"
    #${OC} annotate -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} machines --all "machine.cluster.x-k8s.io/exclude-node-draining="
    NODEPOOLS=$(${OC} get nodepools -n ${HC_CLUSTER_NS} -o=jsonpath='{.items[?(@.spec.clusterName=="'${HC_CLUSTER_NAME}'")].metadata.name}')

    change_reconciliation "stop"
    backup_etcd
    render_svc_objects
    render_hc_objects
    clean_routes "${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}"
}

function restore_hc() {
    # MGMT2 Context

    if [[ ! -f ${MGMT2_KUBECONFIG} ]]; then
        echo "Destination Cluster Kubeconfig does not exists"
        echo "Dir: ${MGMT2_KUBECONFIG}"
        exit 1
    fi

    export KUBECONFIG=${MGMT2_KUBECONFIG}
    BACKUP_DIR=${HC_CLUSTER_DIR}/backup
    #${OC} delete ns ${HC_CLUSTER_NS} || true
    ${OC} new-project ${HC_CLUSTER_NS} || ${OC} project ${HC_CLUSTER_NS}
    restore_object "secret" ${HC_CLUSTER_NS}
    restore_object "certificate" ${HC_CLUSTER_NS}
    ${OC} new-project ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} || ${OC} project ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "secret" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "hcp" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "cl" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "awscl" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "awsmt" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "awsm" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "machinedeployment" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "machine" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "machineset" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_etcd
    restore_object "np" ${HC_CLUSTER_NS}

}

function restore_svc() {
    export KUBECONFIG=${SVC2_KUBECONFIG}
    for f in $(ls -1 ${BACKUP_DIR}/svc/*); do
      # Delete managed cluster addons first, instead of updating it
      if [[ "$f" == managedclusteraddon-*.yaml ]]; then
        ADDON_NAME=$(cat $f | yq .metadata.name)
        ${OC} delete managedclusteraddon -n ${HC_CLUSTER_ID} ${ADDON_NAME}
      fi

      yq eval 'del(.metadata.ownerReferences,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.status)' $f | ${OC} apply -f -
    done
}

function ocm_migration() {
    echo "The existing management cluster on OCM is:"
    ocm get /api/clusters_mgmt/v1/clusters/${HC_CLUSTER_ID}/hypershift
    echo "Updating the management cluster on OCM..."
    ocm patch /api/clusters_mgmt/v1/clusters/${HC_CLUSTER_ID}/hypershift <<-EOF
{
"management_cluster":"${MGMT2_CLUSTER_NAME}"
}
EOF
}

function teardown_old_hc() {

    export KUBECONFIG=${MGMT_KUBECONFIG}

    # Scale down deployments
    ${OC} scale deployment -n hypershift operator --replicas 0
    ${OC} scale deployment -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=0 --all
    ${OC} scale statefulset.apps -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=0 --all
    sleep 15


    # Delete Nodepools
    NODEPOOLS=$(${OC} get nodepools -n ${HC_CLUSTER_NS} -o=jsonpath='{.items[?(@.spec.clusterName=="'${HC_CLUSTER_NAME}'")].metadata.name}')
    if [[ ! -z "${NODEPOOLS}" ]];then
        for nodepool in ${NODEPOOLS}
        do
            ${OC} patch -n "${HC_CLUSTER_NS}" nodepool ${nodepool} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]'
            ${OC} delete np -n ${HC_CLUSTER_NS} ${nodepool}
        done
    fi

    # Machines
    for m in $(${OC} get machines.cluster.x-k8s.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name); do
        ${OC} patch -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} ${m} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]' || true
        ${OC} delete -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} ${m} || true
    done

    ${OC} delete machineset.cluster.x-k8s.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --all || true

    # Cluster
    C_NAME=$(${OC} get cluster -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name)
    ${OC} patch -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} ${C_NAME} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]'
    ${OC} delete cluster.cluster.x-k8s.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --all

    # AWS Machines
    for m in $(${OC} get awsmachine.infrastructure.cluster.x-k8s.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name)
    do
        ${OC} patch -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} ${m} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]' || true
        ${OC} delete -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} ${m} || true
    done

    # Service
     ${OC} patch -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} service private-router --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]' || true

    # Awsendpointservice
    ${OC} patch -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} awsendpointservice private-router --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]' || true

    # HCP
    ${OC} patch -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} hostedcontrolplane.hypershift.openshift.io ${HC_CLUSTER_NAME} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]'
    ${OC} delete hostedcontrolplane.hypershift.openshift.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --all

    ${OC} delete ns ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} || true

    ${OC} -n ${HC_CLUSTER_NS} patch hostedclusters ${HC_CLUSTER_NAME} -p '{"metadata":{"finalizers":null}}' --type merge || true
    ${OC} delete hc -n ${HC_CLUSTER_NS} ${HC_CLUSTER_NAME}  --wait=false || true
    ${OC} -n ${HC_CLUSTER_NS} patch hostedclusters ${HC_CLUSTER_NAME} -p '{"metadata":{"finalizers":null}}' --type merge || true
    ${OC} delete hc -n ${HC_CLUSTER_NS} ${HC_CLUSTER_NAME}  || true

    ${OC} scale deployment -n hypershift operator --replicas 2

    ${OC} delete ns ${HC_CLUSTER_NS} || true
}

function teardown_old_klusterlet() {

    export KUBECONFIG=${MGMT_KUBECONFIG}

    # Klusterlet + NS
    ${OC} delete klusterlet klusterlet-${HC_CLUSTER_ID} --wait=false
    ${OC} patch klusterlet klusterlet-${HC_CLUSTER_ID} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]' || true
    ${OC} delete klusterlet klusterlet-${HC_CLUSTER_ID} --ignore-not-found=true

    ${OC} delete ns klusterlet-${HC_CLUSTER_ID} --wait=false
    for p in $(${OC} get configurationpolicy -n klusterlet-${HC_CLUSTER_ID} -o name)
    do
        ${OC} patch -n klusterlet-${HC_CLUSTER_ID} ${p} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]' || true
    done
    ${OC} delete ns klusterlet-${HC_CLUSTER_ID} --ignore-not-found=true
}

function restore_ovn_pods() {
    echo "Deleting OVN Pods in Guest Cluster to reconnect with new OVN Master"

    ${OC} --kubeconfig=${HC_KUBECONFIG} delete pod -n openshift-ovn-kubernetes --all --wait=false --grace-period=0
}

function restart_kube_apiserver() {
    echo "Restart audit-webook, kube-apiserver, and openshift-route-controller-manager to fix intermittent api issues"
    export KUBECONFIG=${MGMT2_KUBECONFIG}
    ${OC} scale -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=0 deployment/audit-webhook
    ${OC} scale -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=2 deployment/audit-webhook
    for i in {1..36}; do
        STATUS=$(${OC} get deployment -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} audit-webhook -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
        if [ "$STATUS" == "True" ]; then
            break
        fi

        if [ $i -eq 36 ]; then
            echo "Timed-out waiting for audit-webhook to be restarted"
        else 
            sleep 5
        fi
    done

    ${OC} scale -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=0 deployment/kube-apiserver
    ${OC} scale -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=3 deployment/kube-apiserver
    for i in {1..36}; do
        STATUS=$(${OC} get deployment -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} kube-apiserver -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
        if [ "$STATUS" == "True" ]; then
            break
        fi

        if [ $i -eq 36 ]; then
            echo "Timed-out waiting for kube-apiserver to be restarted"
        else 
            sleep 5
        fi
    done

    ${OC} scale -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=0 deployment/openshift-route-controller-manager
    ${OC} scale -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=3 deployment/openshift-route-controller-manager
}

function readd_appliedmanifestwork_ownerref() {
    export KUBECONFIG=${MGMT2_KUBECONFIG}
    export AMW=$(${OC} get appliedmanifestwork --no-headers -o custom-columns=name:.metadata.name | grep ${HC_CLUSTER_ID}$)
    export AMW_UID=$(${OC} get appliedmanifestwork $AMW -o go-template='{{ .metadata.uid }}')
    export AMW_NAME=$(${OC} get appliedmanifestwork $AMW -o go-template='{{ .metadata.name }}')
    ${OC} -n ${HC_CLUSTER_NS} patch hostedcluster ${HC_CLUSTER_NAME} --patch "{\"metadata\":{\"ownerReferences\":[{\"apiVersion\":\"work.open-cluster-management.io/v1\",\"kind\":\"AppliedManifestWork\",\"name\":\"$AMW_NAME\",\"uid\":\"$AMW_UID\"}]}}" --type=merge
}

function teardown_old_svc() {
    export KUBECONFIG=${SVC_KUBECONFIG}
    ${OC} delete manifestwork -n ${MGMT_CLUSTER_NAME} addon-config-policy-controller-deploy-hosting-${HC_CLUSTER_ID}-0 addon-governance-policy-framework-deploy-hosting-${HC_CLUSTER_ID}-0 addon-work-manager-deploy-hosting-${HC_CLUSTER_ID}-0 ${HC_CLUSTER_ID}-hosted-klusterlet
}

helpFunc()
{
   echo ""
   echo "Usage: $0 HC_CLUSTER_ID HC_CLUSTER_NAME -e HC_ENV -p HC_PASS"
   exit 1 
}

REPODIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."

source $REPODIR/dr-script/common.sh

if [ "$#" -lt 2 ]; then
  helpFunc
  exit 1
fi

HC_CLUSTER_ID="$1"
if [ -z $HC_CLUSTER_ID ]; then
    echo "No value for HC_CLUSTER_ID parameter specified"
    exit 1
fi
shift

HC_CLUSTER_NAME="$1"
if [ -z $HC_CLUSTER_NAME ]; then
    echo "No value for HC_CLUSTER_NAME parameter specified"
    exit 1
fi
shift

HC_PASS=""
while getopts "e:p:" opt
do
   case "$opt" in
      e ) HC_ENV="${OPTARG}" ;;
      p ) HC_PASS="${OPTARG}" ;;
      ? ) helpFunc ;; 
   esac
done

if [ -z $HC_CLUSTER_NS ]; then
    if [ -z $HC_ENV ]; then
        echo "No value for HC_CLUSTER_NS or HC_ENV parameter specified"
        exit 1
    fi

    HC_CLUSTER_NS="${HC_ENV}-${HC_CLUSTER_ID}"
fi

if [ -z $HC_PASS ]; then
    echo "No value for HC_PASS parameter specified. Trying to get the bootstrap one from management cluster."
    get_hc_kubeadmin_pass

    if [ -z $HC_PASS ]; then
        echo "No value for HC_PASS parameter specified. Provide the value by using the -p parameter."
        exit 1
    fi
fi

HC_CLUSTER_DIR="${BASE_PATH}/${HC_CLUSTER_NAME}"
HC_KUBECONFIG="${HC_CLUSTER_DIR}/kubeconfig"
BACKUP_DIR=${HC_CLUSTER_DIR}/backup

## Backup
echo "Creating Backup of the HC"
SECONDS=0
backup_hc
echo "Backup Done!"
ELAPSED="Elapsed: $(($SECONDS / 3600))hrs $((($SECONDS / 60) % 60))min $(($SECONDS % 60))sec"
echo $ELAPSED

## Migration
SECONDS=0
echo "Executing the HC Migration"
restore_hc
restore_svc
echo "Restoration Done!"
ELAPSED="Elapsed: $(($SECONDS / 3600))hrs $((($SECONDS / 60) % 60))min $(($SECONDS % 60))sec"
echo $ELAPSED

## Teardown
SECONDS=0
echo "Tearing down the HC in Source Management Cluster"
teardown_old_svc
teardown_old_hc
teardown_old_klusterlet
# old HC kubeconfig before migration is no longer valid after migration
get_hc_kubeconfig 200
restore_ovn_pods
restart_kube_apiserver
readd_appliedmanifestwork_ownerref
echo "Teardown Done"
ELAPSED="Elapsed: $(($SECONDS / 3600))hrs $((($SECONDS / 60) % 60))min $(($SECONDS % 60))sec"
echo $ELAPSED

## OCM Migration commands
echo "Executing OCM migration commands"
ocm_migration
echo "OCM migration commands Done!"
