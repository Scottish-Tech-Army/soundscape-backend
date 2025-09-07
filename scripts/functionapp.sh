#!/bin/bash
# Set up initial deployment.
set -euo pipefail
echo "RG: ${RG}"

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."

# Before running this, you must be logged into your account, with the correct subscription selected.
echo "Build and push Azure trigger function"
pushd src/trigger
func azure functionapp publish ${TRIGGERAPPNAME} --python
popd

pushd src/vmcount
func azure functionapp publish ${METRICAPPNAME} --python
popd

echo "SUCCESS"