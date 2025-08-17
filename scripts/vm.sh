#!/bin/bash
# Set up initial deployment.
set -euo pipefail
echo "RG: ${RG}"

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."

# Before running this, you must be logged into your account, with the correct subscription selected.

# Build the tar file of scripts
mkdir -p tmp
pushd Docker
tar -zcvf ../tmp/files.tgz requirements.txt ingest_simple.py config.json mapping.yml extracts/
popd

# Create the group
az deployment group create \
    --resource-group ${RG} --template-file templates/vm.bicep \
    --parameters suffix=${SUFFIX} --debug --verbose # Uncomment for debugging

echo "SUCCESS"