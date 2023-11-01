#!/bin/bash

set -eux

function get_hc_kubeconfig() {
  export KUBECONFIG=${HC_KUBECONFIG}
  oc login $(rosa describe cluster -c ${HC_CLUSTER_ID} -o json | jq -r .api.url) -u cluster-admin -p ${HC_PASS}
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
            oc patch -n ${HC_CLUSTER_NS} hostedclusters/${HC_CLUSTER_NAME} -p '{"spec":{"pausedUntil":"'${PAUSED_UNTIL}'"}}' --type=merge
            oc patch -n ${HC_CLUSTER_NS} nodepools/${NODEPOOLS} -p '{"spec":{"pausedUntil":"'${PAUSED_UNTIL}'"}}' --type=merge
            oc scale deployment -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=0 kube-apiserver openshift-apiserver openshift-oauth-apiserver control-plane-operator
            ;;
        "start")
            # Restart reconciliation of HC and NP and ETCD writers
            PAUSED_UNTIL="false"
            oc patch -n ${HC_CLUSTER_NS} hostedclusters/${HC_CLUSTER_NAME} -p '{"spec":{"pausedUntil":"'${PAUSED_UNTIL}'"}}' --type=merge
            oc patch -n ${HC_CLUSTER_NS} nodepools/${NODEPOOLS} -p '{"spec":{"pausedUntil":"'${PAUSED_UNTIL}'"}}' --type=merge
            oc scale deployment -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=1 kube-apiserver openshift-apiserver openshift-oauth-apiserver control-plane-operator
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
    oc exec -it ${POD} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -- env ETCDCTL_API=3 /usr/bin/etcdctl --cacert ${ETCD_CA_LOCATION} --cert /etc/etcd/tls/client/etcd-client.crt --key /etc/etcd/tls/client/etcd-client.key --endpoints=localhost:2379 snapshot save /var/lib/data/snapshot.db

    oc exec -it ${POD} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -- env ETCDCTL_API=3 /usr/bin/etcdctl -w table snapshot status /var/lib/data/snapshot.db

    FILEPATH="/${BUCKET_NAME}/${HC_CLUSTER_NAME}-${POD}-snapshot.db"
    CONTENT_TYPE="application/x-compressed-tar"
    DATE_VALUE=`date -R`
    SIGNATURE_STRING="PUT\n\n${CONTENT_TYPE}\n${DATE_VALUE}\n${FILEPATH}"

    #set +x
    ACCESS_KEY=$(grep aws_access_key_id ${AWS_CREDS} | head -n1 | cut -d= -f2 | sed "s/ //g")
    SECRET_KEY=$(grep aws_secret_access_key ${AWS_CREDS} | head -n1 | cut -d= -f2 | sed "s/ //g")
    SIGNATURE_HASH=$(echo -en ${SIGNATURE_STRING} | openssl sha1 -hmac "${SECRET_KEY}" -binary | base64)

    oc exec -it etcd-0 -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -- curl -X PUT -T "/var/lib/data/snapshot.db" \
      -H "Host: ${BUCKET_NAME}.s3.amazonaws.com" \
      -H "Date: ${DATE_VALUE}" \
      -H "Content-Type: ${CONTENT_TYPE}" \
      -H "Authorization: AWS ${ACCESS_KEY}:${SIGNATURE_HASH}" \
      https://${BUCKET_NAME}.s3.amazonaws.com/${HC_CLUSTER_NAME}-${POD}-snapshot.db
}

function render_hc_objects {
    # Backup resources
    mkdir -p ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS} ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    chmod 700 ${BACKUP_DIR}/namespaces/

    export KUBECONFIG="${MGMT_KUBECONFIG}"

    # Certificates
    echo "Backing Up Certificate Objects:"
    oc get certificate cluster-api-cert -n ${HC_CLUSTER_NS} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/certificate-cluster-api-cert.yaml
    echo "--> Certificate"
    # sed -i -e '/^status:$/,$d' ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}.yaml

    # HostedCluster
    echo "Backing Up HostedCluster Objects:"
    oc get hc ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}.yaml
    echo "--> HostedCluster"
    sed -i -e '/^status:$/,$d' ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}.yaml

    # NodePool
    oc get np ${NODEPOOLS} -n ${HC_CLUSTER_NS} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/np-${NODEPOOLS}.yaml
    echo "--> NodePool"
    sed -i -e '/^status:$/,$ d' ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/np-${NODEPOOLS}.yaml

    # Secrets in the HC Namespace
    echo "--> HostedCluster Secrets"
    for s in $(oc get secret -n ${HC_CLUSTER_NS}  | grep "^${HC_CLUSTER_NAME}" | awk '{print $1}'); do
        oc get secret -n ${HC_CLUSTER_NS} $s -o yaml  > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/secret-${s}.yaml
    done

    echo "--> HostedCluster Secrets"
    for s in $(oc get secret -n ${HC_CLUSTER_NS}  | grep bound | awk '{print $1}'); do
        oc get secret -n ${HC_CLUSTER_NS} $s -o yaml  > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/secret-${s}.yaml
    done
    for s in $(oc get secret -n ${HC_CLUSTER_NS}  | grep htpasswd-secret | awk '{print $1}'); do
        oc get secret -n ${HC_CLUSTER_NS} $s -o yaml  > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/secret-${s}.yaml
    done

    # Secrets in the HC Control Plane Namespace
    echo "--> HostedCluster ControlPlane Secrets"
    for s in $(oc get secret -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}  | egrep -v "docker|service-account-token|oauth-openshift|NAME|token-${HC_CLUSTER_NAME}" | awk '{print $1}'); do
        oc get secret  -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/secret-${s}.yaml
    done

    # Hosted Control Plane
    echo "--> HostedControlPlane"
    oc get hcp ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/hcp-${HC_CLUSTER_NAME}.yaml

    # Cluster
    echo "--> Cluster"
    CL_NAME=$(oc get hcp ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o jsonpath={.metadata.labels.\*})
    oc get cluster ${CL_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/cl-${HC_CLUSTER_NAME}.yaml

    # AWS Cluster
    echo "--> AWS Cluster"
    oc get awscluster ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/awscl-${HC_CLUSTER_NAME}.yaml

    # AWS MachineTemplate
    echo "--> AWS Machine Template"
    MT_NAME=$(oc get awsmachinetemplate -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o json | jq -r '.items[0].metadata.name')
    oc get awsmachinetemplate ${MT_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/awsmt-${HC_CLUSTER_NAME}.yaml

    # AWS Machines
    echo "--> AWS Machine"
    CL_NAME=$(oc get hcp ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o jsonpath={.metadata.labels.\*})
    for s in $(oc get awsmachines -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --no-headers | grep ${CL_NAME} | cut -f 1 -d\ ); do
        oc get -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} awsmachines $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/awsm-${s}.yaml
    done

    # MachineDeployments
    echo "--> HostedCluster MachineDeployments"
    for s in $(oc get machinedeployment -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name); do
        mdp_name=$(echo ${s} | cut -f 2 -d /)
        oc get -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/machinedeployment-${mdp_name}.yaml
    done

    # MachineSets
    echo "--> HostedCluster MachineSets"
    for s in $(oc get machineset.cluster.x-k8s.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name); do
        ms_name=$(echo ${s} | cut -f 2 -d /)
        oc get -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/machineset-${ms_name}.yaml
    done

    # Machines
    echo "--> HostedCluster Machines"
    for s in $(oc get machine.cluster.x-k8s.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name); do
        m_name=$(echo ${s} | cut -f 2 -d /)
        oc get -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/machine-${m_name}.yaml
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
      ETCD_SNAPSHOT="s3://${BUCKET_NAME}/${HC_CLUSTER_NAME}-${POD}-snapshot.db"
      ETCD_SNAPSHOT_URL=$(AWS_DEFAULT_REGION=${MGMT2_REGION} aws s3 presign ${ETCD_SNAPSHOT})

      # FIXME no CLI support for restoreSnapshotURL yet
      cat >> ${HC_RESTORE_FILE} <<EOF
        - "${ETCD_SNAPSHOT_URL}"
EOF
    done

    cat ${HC_RESTORE_FILE}

    if ! grep ${HC_CLUSTER_NAME}-snapshot.db ${HC_NEW_FILE}; then
      sed -i -e "/type: PersistentVolume/r ${HC_RESTORE_FILE}" ${HC_NEW_FILE}
      sed -i -e '/pausedUntil:/d' ${HC_NEW_FILE}
    fi

    HC=$(oc get hc -n ${HC_CLUSTER_NS} ${HC_CLUSTER_NAME} -o name || true)
    if [[ ${HC} == "" ]];then
        echo "Deploying HC Cluster: ${HC_CLUSTER_NAME} in ${HC_CLUSTER_NS} namespace"
        oc apply -f ${HC_NEW_FILE}
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
                yq 'del(.metadata.ownerReferences,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.status)' $f | oc apply -f -
            done
            ;;
        "certificate")
            for f in $(ls -1 ${BACKUP_DIR}/namespaces/${2}/${1}-*); do
                yq 'del(.metadata.ownerReferences,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.status)' $f | oc apply -f -
            done
            ;;
        "hc")
            # Cleaning the YAML files before apply them
            for f in $(ls -1 ${BACKUP_DIR}/namespaces/${2}/${1}-*); do
                yq 'del(.metadata.ownerReferences,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.status,.spec.pausedUntil)' $f | oc apply -f -
            done
            ;;
        "np")
            # Cleaning the YAML files before apply them
            for f in $(ls -1 ${BACKUP_DIR}/namespaces/${2}/${1}-*); do
                yq 'del(.metadata.annotations,.metadata.ownerReferences,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.status,.spec.pausedUntil)' $f | oc apply -f -
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

    oc delete route -n ${1} --all
}

function render_svc_objects() {
    BACKUP_DIR=${HC_CLUSTER_DIR}/backup
    mkdir -p ${BACKUP_DIR}/svc
    # Change kubeconfig to service cluster
    export KUBECONFIG="${SVC_KUBECONFIG}"

    # ManagedCluster
    echo "Backing Up HostedCluster Objects:"
    oc get managedcluster ${HC_CLUSTER_ID} -o yaml > ${BACKUP_DIR}/svc/managedcluster-${HC_CLUSTER_ID}.yaml
    echo "--> ManagedCluster"
    sed -i -e '/^status:$/,$d' ${BACKUP_DIR}/svc/managedcluster-${HC_CLUSTER_ID}.yaml
    sed -i -e "s/${MGMT_CLUSTER_NAME}/${MGMT2_CLUSTER_NAME}/g" ${BACKUP_DIR}/svc/managedcluster-${HC_CLUSTER_ID}.yaml

    # ManagedClusterAddOns
    oc get managedclusteraddons -n ${HC_CLUSTER_ID} config-policy-controller -o yaml > ${BACKUP_DIR}/svc/managedclusteraddon-config-policy-controller-${HC_CLUSTER_ID}.yaml
    echo "--> config-policy-controller ManagedClusterAddOn"
    sed -i -e '/^status:$/,$d' ${BACKUP_DIR}/svc/managedclusteraddon-config-policy-controller-${HC_CLUSTER_ID}.yaml
    sed -i -e "s/${MGMT_CLUSTER_NAME}/${MGMT2_CLUSTER_NAME}/g" ${BACKUP_DIR}/svc/managedclusteraddon-config-policy-controller-${HC_CLUSTER_ID}.yaml

    oc get managedclusteraddons -n ${HC_CLUSTER_ID} governance-policy-framework -o yaml > ${BACKUP_DIR}/svc/managedclusteraddon-governance-policy-framework-${HC_CLUSTER_ID}.yaml
    echo "--> governance-policy-framework ManagedClusterAddOn"
    sed -i -e '/^status:$/,$d' ${BACKUP_DIR}/svc/managedclusteraddon-governance-policy-framework-${HC_CLUSTER_ID}.yaml
    sed -i -e "s/${MGMT_CLUSTER_NAME}/${MGMT2_CLUSTER_NAME}/g" ${BACKUP_DIR}/svc/managedclusteraddon-governance-policy-framework-${HC_CLUSTER_ID}.yaml

    oc get managedclusteraddons -n ${HC_CLUSTER_ID} work-manager -o yaml > ${BACKUP_DIR}/svc/managedclusteraddon-work-manager-${HC_CLUSTER_ID}.yaml
    echo "--> work-manager ManagedClusterAddOn"
    sed -i -e '/^status:$/,$d' ${BACKUP_DIR}/svc/managedclusteraddon-work-manager-${HC_CLUSTER_ID}.yaml
    sed -i -e "s/${MGMT_CLUSTER_NAME}/${MGMT2_CLUSTER_NAME}/g" ${BACKUP_DIR}/svc/managedclusteraddon-work-manager-${HC_CLUSTER_ID}.yaml

    # ManifestWork
    oc get manifestwork -n ${MGMT_CLUSTER_NAME} ${HC_CLUSTER_ID} -o yaml > ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}.yaml
    echo "--> ${HC_CLUSTER_ID} ManifestWork"
    sed -i -e '/^status:$/,$d' ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}.yaml
    sed -i -e "s/${MGMT_CLUSTER_NAME}/${MGMT2_CLUSTER_NAME}/g" ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}.yaml
    oc patch manifestwork -n ${MGMT_CLUSTER_NAME} ${HC_CLUSTER_ID} --type=merge --patch '{"spec":{"deleteOption":{"propagationPolicy":"Orphan"}}}'

    oc get manifestwork -n ${MGMT_CLUSTER_NAME} ${HC_CLUSTER_ID}-00-namespaces -o yaml > ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}-00-namespaces.yaml
    echo "--> ${HC_CLUSTER_ID}-00-namespaces ManifestWork"
    sed -i -e '/^status:$/,$d' ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}-00-namespaces.yaml
    sed -i -e "s/${MGMT_CLUSTER_NAME}/${MGMT2_CLUSTER_NAME}/g" ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}-00-namespaces.yaml
    oc patch manifestwork -n ${MGMT_CLUSTER_NAME} ${HC_CLUSTER_ID}-00-namespaces --type=merge --patch '{"spec":{"deleteOption":{"propagationPolicy":"Orphan"}}}'

    oc get manifestwork -n ${MGMT_CLUSTER_NAME} ${HC_CLUSTER_ID}-workers -o yaml > ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}-workers.yaml
    echo "--> ${HC_CLUSTER_ID}-workers ManifestWork"
    sed -i -e '/^status:$/,$d' ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}-workers.yaml
    sed -i -e "s/${MGMT_CLUSTER_NAME}/${MGMT2_CLUSTER_NAME}/g" ${BACKUP_DIR}/svc/manifestwork-${HC_CLUSTER_ID}-workers.yaml
    oc patch manifestwork -n ${MGMT_CLUSTER_NAME} ${HC_CLUSTER_ID}-workers --type=merge --patch '{"spec":{"deleteOption":{"propagationPolicy":"Orphan"}}}'

    # This will be recreated upon updating the managedcluster so we don't back it up
    oc patch manifestwork -n ${MGMT_CLUSTER_NAME} ${HC_CLUSTER_ID}-hosted-klusterlet --type=merge --patch '{"spec":{"deleteOption":{"propagationPolicy":"Orphan"}}}'

    oc delete manifestwork -n ${MGMT_CLUSTER_NAME} ${HC_CLUSTER_ID} ${HC_CLUSTER_ID}-00-namespaces ${HC_CLUSTER_ID}-workers
}

function backup_hc() {
    BACKUP_DIR=${HC_CLUSTER_DIR}/backup
                
    if [ -d ${BACKUP_DIR} ]; then
        echo "There is an existing backup in ${BACKUP_DIR}. Remove it before starting a new backup."
        exit 1          
    fi

    # Create a ConfigMap on the guest so we can tell which management cluster it came from
    export KUBECONFIG=${HC_KUBECONFIG}
    oc create configmap ${USER}-dev-cluster -n default --from-literal=from=${MGMT_CLUSTER_NAME} || true

    # Change kubeconfig to management cluster
    export KUBECONFIG="${MGMT_KUBECONFIG}"
    #oc annotate -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} machines --all "machine.cluster.x-k8s.io/exclude-node-draining="
    NODEPOOLS=$(oc get nodepools -n ${HC_CLUSTER_NS} -o=jsonpath='{.items[?(@.spec.clusterName=="'${HC_CLUSTER_NAME}'")].metadata.name}')

    get_hc_kubeconfig
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
    #oc delete ns ${HC_CLUSTER_NS} || true
    oc new-project ${HC_CLUSTER_NS} || oc project ${HC_CLUSTER_NS}
    restore_object "secret" ${HC_CLUSTER_NS}
    restore_object "certificate" ${HC_CLUSTER_NS}
    oc new-project ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} || oc project ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
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
      yq 'del(.metadata.ownerReferences,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.status)' $f | oc apply -f -
    done
}

function teardown_old_hc() {

    export KUBECONFIG=${MGMT_KUBECONFIG}

    # Scale down deployments
    oc scale deployment -n hypershift operator --replicas 0
    oc scale deployment -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=0 --all
    oc scale statefulset.apps -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=0 --all
    sleep 15


    # Delete Nodepools
    NODEPOOLS=$(oc get nodepools -n ${HC_CLUSTER_NS} -o=jsonpath='{.items[?(@.spec.clusterName=="'${HC_CLUSTER_NAME}'")].metadata.name}')
    if [[ ! -z "${NODEPOOLS}" ]];then
        oc patch -n "${HC_CLUSTER_NS}" nodepool ${NODEPOOLS} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]'
        oc delete np -n ${HC_CLUSTER_NS} ${NODEPOOLS}
    fi

    # Machines
    for m in $(oc get machines.cluster.x-k8s.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name); do
        oc patch -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} ${m} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]' || true
        oc delete -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} ${m} || true
    done

    oc delete machineset.cluster.x-k8s.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --all || true

    # Cluster
    C_NAME=$(oc get cluster -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name)
    oc patch -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} ${C_NAME} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]'
    oc delete cluster.cluster.x-k8s.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --all

    # AWS Machines
    for m in $(oc get awsmachine.infrastructure.cluster.x-k8s.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name)
    do
        oc patch -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} ${m} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]' || true
        oc delete -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} ${m} || true
    done

    # Service
     oc patch -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} service private-router --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]' || true

    # Awsendpointservice
    oc patch -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} awsendpointservice private-router --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]' || true

    # HCP
    oc patch -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} hostedcontrolplane.hypershift.openshift.io ${HC_CLUSTER_NAME} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]'
    oc delete hostedcontrolplane.hypershift.openshift.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --all

    oc delete ns ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} || true

    oc -n ${HC_CLUSTER_NS} patch hostedclusters ${HC_CLUSTER_NAME} -p '{"metadata":{"finalizers":null}}' --type merge || true
    oc delete hc -n ${HC_CLUSTER_NS} ${HC_CLUSTER_NAME}  --wait=false || true
    oc -n ${HC_CLUSTER_NS} patch hostedclusters ${HC_CLUSTER_NAME} -p '{"metadata":{"finalizers":null}}' --type merge || true
    oc delete hc -n ${HC_CLUSTER_NS} ${HC_CLUSTER_NAME}  || true

    oc scale deployment -n hypershift operator --replicas 2

    oc delete ns ${HC_CLUSTER_NS} || true
}

function teardown_old_klusterlet() {

    export KUBECONFIG=${MGMT_KUBECONFIG}

    # Klusterlet + NS
    oc delete klusterlet klusterlet-${HC_CLUSTER_ID} --wait=false
    oc patch klusterlet klusterlet-${HC_CLUSTER_ID} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]' || true
    oc delete klusterlet klusterlet-${HC_CLUSTER_ID} --ignore-not-found=true

    oc delete ns klusterlet-${HC_CLUSTER_ID} --wait=false
    for p in $(oc get configurationpolicy -n klusterlet-${HC_CLUSTER_ID} -o name)
    do
        oc patch -n klusterlet-${HC_CLUSTER_ID} ${p} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]' || true
    done
    oc delete ns klusterlet-${HC_CLUSTER_ID} --ignore-not-found=true
}

function restore_ovn_pods() {
    echo "Deleting OVN Pods in Guest Cluster to reconnect with new OVN Master"
    while ! oc --kubeconfig=${HC_KUBECONFIG} delete pod -n openshift-ovn-kubernetes --all --wait=false --grace-period=0; do sleep 3; done
}

function restart_kube_apiserver() {
    echo "Restart audit-webook, kube-apiserver, and openshift-route-controller-manager to fix intermittent api issues"
    export KUBECONFIG=${MGMT2_KUBECONFIG}
    oc scale -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=0 deployment/audit-webhook
    oc scale -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=2 deployment/audit-webhook
    while ! [ "$(oc get po -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} | grep audit-webhook | grep Running | wc -l)" == "2" ]; do sleep 10; done
    oc scale -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=0 deployment/kube-apiserver
    oc scale -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=3 deployment/kube-apiserver
    while ! [ "$(oc get po -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} | grep kube-apiserver | grep Running | wc -l)" == "3" ]; do sleep 10; done
    oc scale -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=0 deployment/openshift-route-controller-manager
    oc scale -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=3 deployment/openshift-route-controller-manager
}

function readd_appliedmanifestwork_ownerref() {
    export KUBECONFIG=${MGMT2_KUBECONFIG}
    export AMW=$(oc get appliedmanifestwork --no-headers -o custom-columns=name:.metadata.name | grep ${HC_CLUSTER_ID}$)
    export AMW_UID=$(oc get appliedmanifestwork $AMW -o go-template='{{ .metadata.uid }}')
    export AMW_NAME=$(oc get appliedmanifestwork $AMW -o go-template='{{ .metadata.name }}')
    oc -n ${HC_CLUSTER_NS} patch hostedcluster ${HC_CLUSTER_NAME} --patch "{\"metadata\":{\"ownerReferences\":[{\"apiVersion\":\"work.open-cluster-management.io/v1\",\"kind\":\"AppliedManifestWork\",\"name\":\"$AMW_NAME\",\"uid\":\"$AMW_UID\"}]}}" --type=merge
}

function teardown_old_svc() {
    export KUBECONFIG=${SVC_KUBECONFIG}
    oc delete manifestwork -n ${MGMT_CLUSTER_NAME} addon-config-policy-controller-deploy-hosting-${HC_CLUSTER_ID}-0 addon-governance-policy-framework-deploy-hosting-${HC_CLUSTER_ID}-0 addon-work-manager-deploy-hosting-${HC_CLUSTER_ID}-0 ${HC_CLUSTER_ID}-hosted-klusterlet
}

helpFunc()
{
   echo ""
   echo "Usage: $0 -i HC_CLUSTER_ID -n HC_CLUSTER_NAME -s HC_CLUSTER_NS -p HC_PASS"
   exit 1 
}

REPODIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."

source $REPODIR/dr-script/common.sh

while getopts "i:n:s:p:" opt
do
   case "$opt" in
      i ) HC_CLUSTER_ID="${OPTARG}" ;;
      n ) HC_CLUSTER_NAME="${OPTARG}" ;;
      s ) HC_CLUSTER_NS="${OPTARG}" ;;
      p ) HC_PASS="${OPTARG}" ;;
      ? ) helpFunc ;; 
   esac
done

if [ -z $HC_CLUSTER_ID ]; then
    echo "No value for HC_CLUSTER_ID parameter specified"
    exit 1
fi

if [ -z $HC_CLUSTER_NAME ]; then
    echo "No value for HC_CLUSTER_NAME parameter specified"
    exit 1
fi

if [ -z $HC_CLUSTER_NS ]; then
    echo "No value for HC_CLUSTER_NS parameter specified"
    exit 1
fi

if [ -z $HC_PASS ]; then
    echo "No value for HC_PASS parameter specified"
    exit 1
fi

HC_CLUSTER_DIR="${BASE_PATH}/${HC_CLUSTER_NAME}"
HC_KUBECONFIG="${HC_CLUSTER_DIR}/kubeconfig"
BACKUP_DIR=${HC_CLUSTER_DIR}/backup

## Backup
echo "Creating ETCD Backup"
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
restore_ovn_pods
restart_kube_apiserver
readd_appliedmanifestwork_ownerref
teardown_old_klusterlet
echo "Teardown Done"
ELAPSED="Elapsed: $(($SECONDS / 3600))hrs $((($SECONDS / 60) % 60))min $(($SECONDS % 60))sec"
echo $ELAPSED
