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
    --resource-group ${RG} --template-file templates/photon.bicep \
    --parameters prefix=${PREFIX} \
                 versionTag=${VERSION} \
                 registryName=${REGISTRYNAME} \
                 registryRG=${REGISTRYRG} \
                 registrySub=${REGISTRYSUB} \
                 registryUAMIName=${REGISTRYUAMI} \
                 area=${AREA} \
                 storageName=${STORAGENAME} --debug --verbose

echo "SUCCESS"