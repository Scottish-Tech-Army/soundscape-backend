#!/bin/bash
# Set up initial deployment.
set -euo pipefail
echo "RG: ${RG}"

# Change to the parent directory of the scripts directory and source utils.
cd "$(dirname "$0")/.."
. scripts/cfgutils.sh

# Before running this, you must be logged into your account, with the correct subscription selected.

# Create the group
az group create --location ${REGION} --resource-group ${RG}

az deployment group create \
    --resource-group ${RG} --template-file templates/iosbase.bicep \
    --parameters prefix=${PREFIX} \
                 versionTag=${VERSION} \
                 registryName=${REGISTRYNAME} \
                 registryRG=${REGISTRYRG} \
                 storageName=${STORAGENAME} --debug --verbose

echo "SUCCESS"