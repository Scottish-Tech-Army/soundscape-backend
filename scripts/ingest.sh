#!/bin/bash
# Runs an initial ingestion.
set -euo pipefail
echo "RG: ${RG}"

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."

# Before running this, you must be logged into your account, with the correct subscription selected.
az deployment group create \
    --resource-group ${RG} --template-file templates/ingest.bicep \
    --parameters suffix=${SUFFIX} \
                 versionTag=${VERSION} \
                 registryName=${REGISTRYNAME} \
                 registryRG=${REGISTRYRG} --debug --verbose # Uncomment for debugging

echo "SUCCESS"