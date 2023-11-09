# Disaster Recovery PoC

## Requirements
`aws`, `oc`, `ocm`, `rosa`, and `yq` binaries in your path.

The required `HCPMigration` role to run the migration `ocm` commands.

## Usage
- Update common.sh with svc, svc2, mgmt, mgmt2, and hc details. If there is only one svc cluster involved fill out the information the same for svc and svc2. 
- Run the migration `pushd dr-script && ./migrate-hcp.sh <cluster-id> <cluster-name> && popd`. For example, `pushd dr-script && ./migrate-hcp.sh 27cndaeif07ns4p6os6gvvbgbhkenu2e some-rosa-hcp && popd`

## TODO:
- There may be other requirements not listed.
- If logged in to ocm we probably have enough to retrieve the kubeconfigs so they don't have to be manually placed on disk.

## Downloads
- aws https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html/
- oc https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/
- ocm https://github.com/openshift-online/ocm-cli/
- rosa https://console.redhat.com/openshift/downloads/
- yq https://github.com/mikefarah/yq/releases/
