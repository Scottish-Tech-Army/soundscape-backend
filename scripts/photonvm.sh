#!/bin/bash
# Set up initial deployment.
set -euo pipefail
echo "RG: ${RG}"

# Change to the parent directory of the scripts directory and source utils.
cd "$(dirname "$0")/.."
. scripts/cfgutils.sh

echo "Building files ready to deploy"
# Build the escaped query file.
mkdir -p build
jq -Rs . templates/vmquery.txt > build/vmquery-escaped.txt
jq -Rs . templates/photonerrorquery.txt > build/error-escaped.txt
jq -Rs . templates/photonrequestquery.txt > build/request-escaped.txt
jq -Rs . templates/photonlegacyquery.txt > build/legacy-escaped.txt

# Build the tar file of scripts
rm -rf build/tmp build/files.tgz
mkdir -p build/tmp
pushd build/tmp
cp -r ../../src/photon/* .
tar -zcf ../files.tgz *
popd

# Returns both key1 and key2; pick either
echo "Getting storage account key"
ACCOUNT_KEY=$(az storage account keys list \
  --resource-group ${RG} \
  --account-name $STORAGENAME \
  --query "[0].value" -o tsv)

# Upload the files to the storage account for download by the VM
echo "Uploading files to storage account"
az storage blob upload-batch \
  --account-name ${STORAGENAME} \
  --account-key "$ACCOUNT_KEY" \
  --destination downloads \
  --source build \
  --pattern files.tgz \
  --overwrite

# Note the "--no-wait" flag, which makes this return promptly. That is because
# the deployment waits for the VM to be fully provisioned, which can take a long time.
echo "Starting deployment of VM - will return before VM is live"
az deployment group create \
    --resource-group ${RG} --template-file templates/photonvm.bicep \
    --parameters prefix=${PREFIX} \
                 versionTag=${VERSION} \
                 registryName=${REGISTRYNAME} \
                 registryRG=${REGISTRYRG} \
                 registryUAMIName=${REGISTRYUAMI} \
                 metricAppName=${METRICAPPNAME} \
                 triggerAppName=${TRIGGERAPPNAME} \
                 diagsRG=${DIAGSRG} \
                 area=${AREA} \
                 debug=${DEBUG} \
                 sharedRGName=${SHAREDRG} \
                 sharedLAW=${SHAREDLAW} \
                 frontDoorName=${FRONTDOOR} \
                 storageName=${STORAGENAME} --no-wait

echo "SUCCESS"