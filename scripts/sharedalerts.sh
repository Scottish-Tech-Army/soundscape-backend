#!/bin/bash
# Set up shared RG
set -euo pipefail
echo "SHAREDRG: ${SHAREDRG}"

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."
# Check we are logged into the correct subscription
az account set --subscription ${SUBSCRIPTION}

# Source the diags config file
. config/diags-cfg.sh

echo "Deploying alerts to resource group"
az deployment group create \
    --resource-group ${SHAREDRG} \
    --template-file templates/sharedalerts.bicep \
    --parameters sharedLAW=${SHAREDLAW} \
                 diagsRG=${DIAGSRG}

echo "SUCCESS"