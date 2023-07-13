# Disaster Recovery PoC

## Requirements
hypershift, oc, rosa, and yq binaries in your path.

## Usage
- Update common/common.sh with svc, svc2, mgmt, mgmt2, and hc details. If there is only one svc cluster involved fill out the information the same for svc and svc2. 
- Run the migration `pushd dr-script && ./migrate-hcp.sh && popd`

## TODO:
- There is a secret with the kubeconfig in it that we should be able to use, but I'm getting cert errors trying to use it to talk to the hosted cluster... could be something in the environment where I just need to import a cert or do something trivial, but using the admin password as above works for now.
- There may be other requirements not listed.
- If logged in to ocm we probably have enough to retrieve the kubeconfigs so they don't have to be manually placed on disk.

## Downloads
- hypershift https://hypershift-docs.netlify.app/getting-started/ (not aware of published binaries)
- oc https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/
- rosa https://console.redhat.com/openshift/downloads
- yq https://github.com/mikefarah/yq/releases
