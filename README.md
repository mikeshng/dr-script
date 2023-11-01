# Disaster Recovery PoC

## Requirements
oc, rosa, and yq binaries in your path.

## Usage
- Update common/common.sh with svc, svc2, mgmt, mgmt2, and hc details. If there is only one svc cluster involved fill out the information the same for svc and svc2. 
- Run the migration `pushd dr-script && ./migrate-hcp.sh && popd`

## TODO:
- There may be other requirements not listed.
- If logged in to ocm we probably have enough to retrieve the kubeconfigs so they don't have to be manually placed on disk.

## Downloads
- oc https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/
- rosa https://console.redhat.com/openshift/downloads
- yq https://github.com/mikefarah/yq/releases
