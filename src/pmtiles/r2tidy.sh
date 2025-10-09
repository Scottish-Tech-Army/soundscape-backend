#!/bin/bash
set -euo pipefail
. ${BASE}/env.sh # Reload env.sh, as the previous script may have added to it
. ${BASE}/utils.sh

svclog "R2 tidy job starting - sleep first to wait for existing requests to complete"
sleep 60

svclog "Burn down the contents of the pmtiles bucket"

# Check that PMTILESFILE is present; if not this errors out.
echo "Checking for presence of ${PMTILESFILE} in R2"
rclone lsf r2:${PMTILES_BUCKET} --include "*.pmtiles" | grep ${PMTILESFILE} > /dev/null

echo "Deleting pmtiles files not matching ${PMTILESFILE}"
rclone delete r2:${PMTILES_BUCKET} --exclude ${PMTILESFILE}

# Now do the extracts bucket
echo "Checking for old extracts content"
rclone lsf r2:${EXTRACTS_BUCKET}/ --dirs-only | grep ${DATESTAMP} > /dev/null
# This command is a bit mucky, so an explanation.
# - list all the directories at the top level of the extracts bucket
# - strip the trailing slashes
# - sort them
# - convert to a space-separated list
FILES=$(rclone lsf r2:${EXTRACTS_BUCKET}/ --dirs-only | sed "s/\///g" | sort | xargs)
echo "Found list of files to consider deleting: ${FILES}"

# Split into array. Sometimes I don't like bash.
set -- ${FILES}
ARRAY=("$@")

# Only proceed if there are at least 3 and the last matches ${DATASTAMP}
if (( ${#ARRAY[@]} < 3 )); then
    echo "Less than 3 items in extracts bucket; not deleting anything"
elif [[ "${ARRAY[-1]}" != "$DATESTAMP" ]]; then
    echo "Last item not ${DATESTAMP} in extracts bucket - do nothing"
else
    # Drop the last element (matches $d)
    unset 'ARRAY[-1]'

    # Drop the new last element (the original second last)
    unset 'ARRAY[-1]'

    # Do something with the remaining elements
    for x in "${ARRAY[@]}"; do
        echo "Delete ${x} from extracts bucket"
        rclone purge r2:${EXTRACTS_BUCKET}/${x}/
    done
fi
