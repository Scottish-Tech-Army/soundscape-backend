#!/bin/bash
# Deploy function apps. This is used for both android and iOS deployments.
set -euo pipefail
echo "RG: ${RG}"

# Change to the parent directory of the scripts directory and source utils.
cd "$(dirname "$0")/.."
. scripts/cfgutils.sh

# Before running this, you must be logged into your account, with the correct subscription selected.
echo "Build and push Azure trigger function"
pushd src/trigger
func azure functionapp publish ${TRIGGERAPPNAME} --python
popd

echo "Build and push VM count function"
pushd src/vmcount
func azure functionapp publish ${METRICAPPNAME} --python
popd

echo "SUCCESS"