#!/bin/bash
# Set up initial deployment.
set -euo pipefail
echo "RG: ${RG}"

# Change to the parent directory of the scripts directory and source utils.
cd "$(dirname "$0")/.."
. scripts/cfgutils.sh

# Build the escaped query file.
mkdir -p build
jq -Rs . templates/vmquery.txt > build/vmquery-escaped.txt

# Build the tar file of scripts
rm -rf build/tmp build/files.tgz
mkdir -p build/tmp
cp -r src/pmtiles/* build/tmp/
cp -r thirdparty/pmtiles/wrangler build/tmp/
pushd build/tmp
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

# Create the group
echo "Create deployment"
az deployment group create \
    --resource-group ${RG} --template-file templates/androidvm.bicep \
    --parameters prefix=${PREFIX} \
                 area=${AREA} \
                 triggerAppName=${TRIGGERAPPNAME} \
                 metricAppName=${METRICAPPNAME} \
                 pmtilesBucket=${PMTILES_BUCKET} \
                 extractsBucket=${EXTRACTS_BUCKET} \
                 storageName=${STORAGENAME} --debug --verbose

echo "SUCCESS"