#!/bin/bash
# Set up initial deployment.
set -euo pipefail
echo "RG: ${RG}"

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."

# Before running this, you must be logged into your account, with the correct subscription selected.

# Build the tar file of scripts
mkdir -p build
pushd src/ingest
tar -zcvf ../../build/files.tgz requirements-ingest.txt ingest.py tilefunc.sql postgis-vt-util.sql config.json mapping.yml extracts/ ../tiletest/
popd

# Build the escaped query file.
jq -Rs . templates/vmquery.txt > build/vmquery-escaped.txt

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
    --resource-group ${RG} --template-file templates/vm.bicep \
    --parameters prefix=${PREFIX} \
                 triggerAppName=${TRIGGERAPPNAME} \
                 metricAppName=${METRICAPPNAME} \
                 storageName=${STORAGENAME} --debug --verbose

echo "SUCCESS"