#!/bin/bash
# Set up global diags resources
set -euo pipefail
echo "DIAGSRG: ${DIAGSRG}"

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."

# Create the group
az group create --location ${DIAGSREGION} --resource-group ${DIAGSRG}

# Before running this, you must be logged into your account, with the correct subscription selected.
az deployment group create \
    --resource-group ${DIAGSRG} --template-file templates/androiddiags.bicep \
    --debug --verbose

echo "SUCCESS"