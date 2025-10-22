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

# Tidy up old files in R2.
bash ${BASE}/r2tidy.sh >> ${LOGFILE} 2>&1

# Obliterate the VM after completion
svclog "Goodbye cruel world"

# Upload logs to the storage account
az login --identity
az storage blob upload-batch \
--auth-mode login \
--account-name ${STORAGE_ACCOUNT_NAME} \
--destination ${UPLOAD_CONTAINER_NAME} \
--source ${BASE}/logs

exit 0

# Sleep for 600 seconds so logs are flushed. Mad overkill, but that's Azure logging delays for you.
sleep 600

# Nuke the VM once and for all
az vmss scale --resource-group ${RG} --name ${VMSS_NAME} --new-capacity 0
