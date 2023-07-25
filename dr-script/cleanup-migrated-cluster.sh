#!/bin/bash

# Currently a migrated hosted cluster does not clean up correctly when 
# `rosa delete cluster` is run. This may be due to ocm no longer being aware of
# where the hosted cluster resides and failing to perform some tasks.
#
# There are two manifestwork resources and a namespace not cleaned up on the 
# SVC cluster. The hostedcluster and hostedcontrolplane namespaces on the new
# mgmt cluster are also not deleted.
source ../common/common.sh

rosa delete cluster -y -c ${HC_CLUSTER_ID}

echo ""
echo "Giving ROSA 10 minutes to clean up what it can"

sleep 10m

echo ""
echo "Cleaning up remaining SVC cluster resources"

# SVC cleanup
export KUBECONFIG=${SVC_KUBECONFIG}
oc delete manifestwork -n ${MGMT2_CLUSTER_NAME} --wait=false ${HC_CLUSTER_ID}-00-namespaces 
oc delete manifestwork -n ${MGMT2_CLUSTER_NAME} --wait=false ${HC_CLUSTER_ID}-workers
oc delete ns ${HC_CLUSTER_NS}

echo ""
echo "Completed cleaning up remaining SVC resources."
echo "Waiting 5 more minutes for nodes to clean up."
sleep 5m

echo ""
echo "Cleaning up remaining MGMT cluster resources"

# MGMT2 cleanup
export KUBECONFIG=${MGMT2_KUBECONFIG}
oc delete ns --wait=false ${HC_CLUSTER_NS}
oc delete ns --wait=false ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}

oc patch -n ${HC_CLUSTER_NS} hostedclusters/${HC_CLUSTER_NAME} --type=merge -p '{"spec":{"pausedUntil":"true"}}'
oc patch -n ${HC_CLUSTER_NS} hostedclusters/${HC_CLUSTER_NAME} --type=json -p '[ { "op":"remove", "path": "/metadata/finalizers" }]'
