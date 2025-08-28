# This script runs tiletest with a good set of useful options.
set -euo pipefail

if [ -d /opt/ingest/logs ]
then
    OUTPUT_DIR="--output /opt/ingest/logs"
else
    OUTPUT_DIR=""
fi

# Run through all the tests in order, sleeping 5 seconds after each one.
python tiletest.py \
    ${OUTPUT_DIR} --shuffle --sleep 5 \
    --base-url ${TILESRV_APP_URL}

