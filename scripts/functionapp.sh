#!/bin/bash
# Set up initial deployment.
set -euo pipefail
echo "RG: ${RG}"

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."

# Before running this, you must be logged into your account, with the correct subscription selected.
echo "Build and push Azure function"
pushd trigger
func azure functionapp publish ${FUNCAPPNAME} --python
popd

echo "SUCCESS"