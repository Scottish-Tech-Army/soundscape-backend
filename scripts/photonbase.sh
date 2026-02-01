#!/bin/bash
# Set up initial deployment.
set -euo pipefail
echo "RG: ${RG}"

# Change to the parent directory of the scripts directory and source utils.
cd "$(dirname "$0")/.."
. scripts/cfgutils.sh

# Create the group
az group create --location ${REGION} --resource-group ${RG}

echo "Deploying resoures"
az deployment group create \
    --resource-group ${RG} --template-file templates/photonbase.bicep \
    --parameters prefix=${PREFIX} \
                 storageName=${STORAGENAME}

echo "Setting up UAMI additional rights"
az deployment group create \
    --resource-group ${REGISTRYRG} --template-file templates/photonregistryuami.bicep \
    --parameters prefix=${PREFIX} \
                 mainRG=${RG} \
                 registryUAMIName=${REGISTRYUAMI}

echo "SUCCESS"