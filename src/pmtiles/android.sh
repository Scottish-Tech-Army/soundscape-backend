#!/bin/bash
# Set up android infrastructure and run everything
set -euo pipefail
ENVFILE="$(dirname "$0")/env.sh"
. ${ENVFILE}
. ${BASE}/utils.sh
. ${BASE}/secrets.sh

LOGFILE="${BASE}/logs/pmtiles_$(date +%Y%m%d_%H%M%S).log"
svclog "Android data processing job starting - output to ${LOGFILE}"

# Run the pmtiles process
bash ${BASE}/pmtiles.sh >> ${LOGFILE} 2>&1

# Run the extracts process
bash ${BASE}/extracts.sh >> ${LOGFILE} 2>&1

# Sleep for 600 seconds before cleaning things up. This means that any clients in the process of downloading extracts
# are not impacted. After this, they just have start reloading again.
svclog "Sleeping for 600 seconds before starting tidy process to allow existing downloads to complete"
sleep 600

# Tidy up old files in R2.
bash ${BASE}/r2tidy.sh >> ${LOGFILE} 2>&1

# Obliterate the VM after completion
svclog "Goodbye cruel world - uploading logs and deleting VM"

# Upload logs to the storage account
az login --identity
az storage blob upload-batch \
--auth-mode login \
--account-name ${STORAGE_ACCOUNT_NAME} \
--destination ${UPLOAD_CONTAINER_NAME} \
--source ${BASE}/logs

# Nuke the VM once and for all
az vmss scale --resource-group ${RG} --name ${VMSS_NAME} --new-capacity 0
