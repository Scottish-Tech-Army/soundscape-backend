#!/bin/bash
# This script terminates the VM nicely after errors. It is called unconditionally from
# cloud-init, but if we get here we know that the previous script failed to clean up the VM.
set -euo pipefail
ENVFILE="$(dirname "$0")/env.sh"
. ${ENVFILE}
. ${BASE}/utils.sh
# secrets.sh only exists if there are secrets to download
[ -f ${BASE}/secrets.sh ] && . ${BASE}/secrets.sh

# Check for whether there was a success or not
if ! grep "VM SUCCESS" "${BASE}/logs/svc-${HOSTNAME}.log"
then
    svclog "VM ERROR"
fi

svclog "Goodbye cruel world - uploading logs and deleting VM"

# Upload cloud-init files to the directory if they exist
cp /var/log/cloud-init.log ${BASE}/logs/cloud-init-${DATESTAMP}.log 2>/dev/null || true
cp /var/log/cloud-init-output.log ${BASE}/logs/cloud-init-output-${DATESTAMP}.log 2>/dev/null || true

# Upload logs to the storage account
az login --identity
az storage blob upload-batch \
--auth-mode login \
--account-name ${STORAGE_ACCOUNT_NAME} \
--destination ${UPLOAD_CONTAINER_NAME} \
--source ${BASE}/logs

# Sleep long enough that the agent has reported all logs to Log Analytics.
sleep 300

# Nuke the VM once and for all
az vmss scale --resource-group ${RG} --name ${VMSS_NAME} --new-capacity 0
