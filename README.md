# Disaster Recovery PoC

## Requirements
hypershift, oc, rosa, and yq binaries in your path.

## Usage
- Update common/common.sh with svc, svc2, mgmt, mgmt2, and hc details. If there is only one svc cluster involved fill out the information the same for svc and svc2. 
- Run the migration `pushd dr-script && ./migrate-hcp.sh && popd`

## TODO:
- There may be other requirements not listed.
- If logged in to ocm we probably have enough to retrieve the kubeconfigs so they don't have to be manually placed on disk.
- Cleanup of the migrated cluster currently does not complete properly. This may be due to OCM no longer knowing where the hosted cluster resides and failing to perform some tasks. For now `cleanup-migrated-cluster.sh` is here to facilitate faster cleanup, but ideally the migration will handle the missing pieces so it becomes necessary. This script should not be run against cluster you don't want destroyed or that hasn't been migrated.

## Downloads
- hypershift https://hypershift-docs.netlify.app/getting-started/ (not aware of published binaries)
- oc https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/
- rosa https://console.redhat.com/openshift/downloads
- yq https://github.com/mikefarah/yq/releases
