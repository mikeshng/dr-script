# Disaster Recovery PoC

## Requirements
hypershift, oc, rosa, and yq binaries in your path.

## Usage
- Update common/common.sh with svc, svc2, mgmt, mgmt2, and hc details. If there is only one svc cluster involved fill out the information the same for svc and svc2. 
- Retrieve the kubeconfig for the hosted cluster
```
  source common/common.sh
  export KUBECONFIG=${MGMT_KUBECONFIG}
  export HCPASS=$(oc get secret -n ${HC_CLUSTER_NS} ${HC_CLUSTER_NAME}-kubeadmin-password -o go-template='{{.data.password}}' | base64 -d)
  export KUBECONFIG=${HC_KUBECONFIG}
  oc login $(rosa describe cluster -c ${HC_CLUSTER_ID} -o json | jq -r .api.url) -u kubeadmin -p ${HCPASS}
```
- Run the migration `pushd dr-script && ./migrate-hcp.sh && popd`

## TODO:
- There is a secret with the kubeconfig in it that we should be able to use, but I'm getting cert errors trying to use it to talk to the hosted cluster... could be something in the environment where I just need to import a cert or do something trivial, but using the admin password as above works for now.
- There may be other requirements not listed.

## Downloads
- hypershift https://hypershift-docs.netlify.app/getting-started/ (not aware of published binaries)
- oc https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/
- rosa https://console.redhat.com/openshift/downloads
- yq https://github.com/mikefarah/yq/releases
