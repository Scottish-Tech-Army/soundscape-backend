#!/bin/bash
# Set up global diags resources
set -euo pipefail
echo "DIAGSRG: ${DIAGSRG}"

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."
# Check we are logged into the correct subscription
az account set --subscription ${SUBSCRIPTION}

# Create the group
az group create --location ${DIAGSREGION} --resource-group ${DIAGSRG}

ACTION_GROUP_NAME="Soundscape"
SHORT_NAME="soundscape"

# Deploy the action group
if az monitor action-group show \
  --name "${ACTION_GROUP_NAME}" \
  --resource-group "${DIAGSRG}" \
  --only-show-errors \
  >/dev/null 2>&1
then
  echo "Action Group '${ACTION_GROUP_NAME}' already exists"
else
  echo "Creating Action Group '${ACTION_GROUP_NAME}'"

  az monitor action-group create \
    --name "${ACTION_GROUP_NAME}" \
    --resource-group "${DIAGSRG}" \
    --short-name "${SHORT_NAME}" \
    --location global
fi

echo "Deploying android diags resources"
az deployment group create \
    --resource-group ${DIAGSRG} --template-file templates/androiddiags.bicep

echo "Deploying iOS diags resources"
az deployment group create \
    --resource-group ${DIAGSRG} --template-file templates/iosdiags.bicep

echo "Deploying photon diags resources"
az deployment group create \
    --resource-group ${DIAGSRG} --template-file templates/photondiags.bicep

echo "SUCCESS"