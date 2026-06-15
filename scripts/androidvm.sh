#!/bin/bash
# Set up initial deployment.
set -euo pipefail
echo "RG: ${RG}"

# Change to the parent directory of the scripts directory and source utils.
cd "$(dirname "$0")/.."
. scripts/cfgutils.sh

if [ -z "${USE_SPOT:-}" ]; then
  echo "USE_SPOT not set - defaulting to true"
  USE_SPOT=true
fi
USE_SPOT=${USE_SPOT,,}  # Lower case as Azure CLI is case sensitive about booleans

# Build escaped query files for workbook charts.
mkdir -p build
jq -Rs . templates/vmquery.txt                  > build/vmquery-escaped.txt
jq -Rs . templates/cf-r2-objects-query.txt      > build/cf-r2-objects-query-escaped.txt
jq -Rs . templates/cf-r2-sizes-query.txt        > build/cf-r2-sizes-query-escaped.txt
jq -Rs . templates/cf-pmtiles-requests-query.txt  > build/cf-pmtiles-requests-query-escaped.txt
jq -Rs . templates/cf-extracts-requests-query.txt > build/cf-extracts-requests-query-escaped.txt

# Build the tar file of scripts
rm -rf build/tmp build/files.tgz
mkdir -p build/tmp
cp -r src/pmtiles/* build/tmp/
cp -r src/vmutils/* build/tmp/
cp -r thirdparty/pmtiles/wrangler build/tmp/
pushd build/tmp
tar -zcf ../files.tgz *
popd

# Returns both key1 and key2; pick either
echo "Getting storage account key"
ACCOUNT_KEY=$(az storage account keys list \
  --resource-group ${RG} \
  --account-name $STORAGENAME \
  --query "[0].value" -o tsv)

# Upload the files to the storage account for download by the VM
echo "Uploading files to storage account"
az storage blob upload-batch \
  --account-name ${STORAGENAME} \
  --account-key "$ACCOUNT_KEY" \
  --destination downloads \
  --source build \
  --pattern files.tgz \
  --overwrite

# The usage-metrics reader writes to the shared metrics Postgres DB (deployed separately
# into ${METRICS_RG}). Read its host + database name from that deployment's outputs so the
# Android function app can be configured to point at it. (The shared metrics infra must
# therefore be deployed before the Android instance — see the deploy docs.)
echo "Reading shared metrics DB connection details from ${METRICS_RG}"
PG_HOST=$(az deployment group show -g ${METRICS_RG} -n metricsdb --query properties.outputs.pgServerFqdn.value -o tsv)
PG_DATABASE=$(az deployment group show -g ${METRICS_RG} -n metricsdb --query properties.outputs.pgDatabaseName.value -o tsv)

# Create the deployment itself
echo "Create deployment"
az deployment group create \
    --resource-group ${RG} --template-file templates/androidvm.bicep \
    --parameters prefix=${PREFIX} \
                 area=${AREA} \
                 triggerAppName=${TRIGGERAPPNAME} \
                 metricAppName=${METRICAPPNAME} \
                 cfMetricsAppName=${CFMETRICSAPPNAME} \
                 usageMetricsAppName=${USAGEMETRICSAPPNAME} \
                 pgHost=${PG_HOST} \
                 pgDatabase=${PG_DATABASE} \
                 pmtilesBucket=${PMTILES_BUCKET} \
                 extractsBucket=${EXTRACTS_BUCKET} \
                 useSpot=${USE_SPOT} \
                 diagsRG=${DIAGSRG} \
                 storageName=${STORAGENAME}

echo "SUCCESS"