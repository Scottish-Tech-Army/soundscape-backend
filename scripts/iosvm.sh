#!/bin/bash
# Set up initial deployment.
set -euo pipefail
echo "RG: ${RG}"

# Change to the parent directory of the scripts directory and source utils.
cd "$(dirname "$0")/.."
. scripts/cfgutils.sh

if [ -z "${USE_SPOT:-}" ]; then
  echo "USE_SPOT not set - defaulting to true"
  USE_SPOT=true
fi
USE_SPOT=${USE_SPOT,,}  # Lower case as Azure CLI is case sensitive about booleans

# Build the tar file of scripts
# Build the tar file of scripts
rm -rf build/tmp build/files.tgz
mkdir -p build/tmp
cp -r src/ingest/* build/tmp/
cp -r src/vmutils/* build/tmp/
cp -r src/tiletest build/tmp/
pushd build/tmp
tar -zcvf ../files.tgz *
popd

# Build the escaped query file.
jq -Rs . templates/vmquery.txt > build/vmquery-escaped.txt
jq -Rs . templates/ioserrorquery.txt > build/error-escaped.txt

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
    --resource-group ${RG} --template-file templates/iosvm.bicep \
    --parameters prefix=${PREFIX} \
                 area=${AREA} \
                 triggerAppName=${TRIGGERAPPNAME} \
                 metricAppName=${METRICAPPNAME} \
                 tilesrvAppName=${TILESRVAPPNAME} \
                 useSpot=${USE_SPOT} \
                 diagsRG=${DIAGSRG} \
                 sharedRGName=${SHAREDRG} \
                 sharedLAW=${SHAREDLAW} \
                 frontDoorName=${FRONTDOOR} \
                 storageName=${STORAGENAME}

echo "SUCCESS"