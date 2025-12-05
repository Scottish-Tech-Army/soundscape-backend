#!/bin/bash
# Set up iOS ingestion
set -euo pipefail
ENVFILE="$(dirname "$0")/env.sh"
. ${ENVFILE}
. ${BASE}/utils.sh

# Ensure venv Python is default for CMD and any shell-in debugging
PATH="${BASE}/venv/bin:$PATH"
export DATESTAMP=$(date +%Y%m%d-%H%M)
echo "export DATESTAMP=${DATESTAMP}" >> ${BASE}/env.sh

LOGFILE="${BASE}/logs/ingest_$(date +%Y%m%d_%H%M%S).log"
svclog "Ingest job starting - output to ${LOGFILE}"

pushd ${BASE}/tiletest
TESTLOG="${BASE}/logs/tiletest_$(date +%Y%m%d_%H%M%S).log"
nohup bash ${BASE}/tiletest/tiletest.sh > ${TESTLOG} 2>&1 &
svclog "Tile perf test started in background, logging to ${TESTLOG}"
popd

# Do the actual ingestion
python3 -u ${BASE}/ingest.py --imposm ${BASE}/imposm3/imposm --mapping ${BASE}/mapping.yml --extracts ${BASE}/extracts/extracts-${GEN_REGIONS}.json \
--basedir ${TILES} --verbose --config ${BASE}/config.json 2>&1 | \
sed -uE 's/^\[([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2})Z\]/\1 \2/' > ${LOGFILE}

# Report success
svclog "VM SUCCESS"
