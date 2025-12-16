#!/bin/bash
# Set up initial deployment.
set -euo pipefail
echo "RG: ${RG}"

# Change to the parent directory of the scripts directory and source utils.
cd "$(dirname "$0")/.."
. scripts/cfgutils.sh

# Create the group
az group create --location ${REGION} --resource-group ${RG}

az deployment group create \
    --resource-group ${RG} --template-file templates/photonbase.bicep \
    --parameters prefix=${PREFIX} \
                 storageName=${STORAGENAME} --debug --verbose

echo "SUCCESS"