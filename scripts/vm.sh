#!/bin/bash
# Set up initial deployment.
set -euo pipefail
echo "RG: ${RG}"

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."

# Before running this, you must be logged into your account, with the correct subscription selected.

# Build the tar file of scripts
mkdir -p build
pushd Docker
tar -zcvf ../build/files.tgz requirements.txt ingest_simple.py tilefunc.sql postgis-vt-util.sql config.json mapping.yml extracts/
popd

# Create the group
echo "Create deployment"
az deployment group create \
    --resource-group ${RG} --template-file templates/vm.bicep \
    --parameters prefix=${PREFIX} functionAppName=${FUNCAPPNAME} --debug --verbose

echo "SUCCESS"