#!/bin/bash
# Set up initial deployment.
set -euo pipefail
echo "RG: ${RG}"

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."

# Before running this, you must be logged into your account, with the correct subscription selected.

# Create the group
az group create --location ${REGION} --resource-group ${RG}

az deployment group create \
    --resource-group ${RG} --template-file templates/deploy.bicep \
    --parameters suffix=${SUFFIX} \
                 versionTag=${VERSION} \
                 registryName=${REGISTRYNAME} \
                 registryRG=${REGISTRYRG} --debug --verbose # Uncomment for debugging

echo "SUCCESS"