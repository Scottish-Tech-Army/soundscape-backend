#!/bin/bash
# Set up initial deployment.
set -euo pipefail
echo "RG: ${RG}"

# Change to the parent directory of the scripts directory and source utils.
cd "$(dirname "$0")/.."
. scripts/cfgutils.sh

# Build the tar file of scripts
rm -rf build/tmp build/files.tgz
mkdir -p build/tmp
pushd build/tmp
cp -r ../../src/photon/* .
tar -zcvf ../files.tgz *
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

az deployment group create \
    --resource-group ${RG} --template-file templates/photonvm.bicep \
    --parameters prefix=${PREFIX} \
                 versionTag=${VERSION} \
                 registryName=${REGISTRYNAME} \
                 registryRG=${REGISTRYRG} \
                 registrySub=${REGISTRYSUB} \
                 registryUAMIName=${REGISTRYUAMI} \
                 area=${AREA} \
                 storageName=${STORAGENAME} \
    --debug --verbose --no-wait

echo "SUCCESS"