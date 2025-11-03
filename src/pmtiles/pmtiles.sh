#!/bin/bash
set -euo pipefail
. ${BASE}/utils.sh

# DATESTAMP is a string something like "20251023-1513"
export DATESTAMP=$(date +%Y%m%d-%H%M)
export PMTILESFILE="${AREA}-${DATESTAMP}.pmtiles"
echo "export PMTILESFILE=${PMTILESFILE}" >> ${BASE}/env.sh
echo "export DATESTAMP=${DATESTAMP}" >> ${BASE}/env.sh

svclog "pmtiles job starting, for area ${AREA}, output ${PMTILESFILE}"

svclog "Creating R2 bucket"
pushd ${BASE}/wrangler
# Create the R2 bucket if it doesn't exist already
export R2_BUCKET=${PMTILES_BUCKET}
envsubst < r2.jsonc > wrangler.jsonc
wrangler r2 bucket info ${PMTILES_BUCKET} || wrangler r2 bucket create ${PMTILES_BUCKET} --location weur
popd # leave wrangler

svclog "Setting up the code"
# Clone the repo with scripts
pushd ${DATADIR}
rm -rf planetiler-openmaptiles
git clone https://github.com/davecraig/planetiler-openmaptiles.git

# Build the code and set everything up ready to download and build the map.
svclog "Download map data"
cd planetiler-openmaptiles
bash scripts/regenerate-openmaptiles.sh

# Build the map.
svclog "Build the map - typically takes four hours for world"
cd soundscape-maps
bash build-map.sh ${AREA}

# Rename the map produced
svclog "Build completed - wrap up"
ln map-to-serve/${AREA}.pmtiles ${DATADIR}/${PMTILESFILE}

# Use rclone to copy the data to R2.
svclog "Copying to R2"
rclone copy ${DATADIR}/${PMTILESFILE} r2:${PMTILES_BUCKET} \
        --progress \
        --s3-upload-concurrency 32 \
        --s3-chunk-size 64M \
        --transfers 32 \
        --retries 10 \
        --low-level-retries 20

# List contents of the /mnt directory.
echo "Contents of ${DATADIR}:"
ls -lh ${DATADIR}
df -h
du -sh ${DATADIR}/*

popd # leave DATADIR

svclog "Cut over worker to use ${PMTILESFILE}"
export PMTILES_PATH="${PMTILESFILE}" # Variable used by tiles-worker.jsonc
pushd ${BASE}/wrangler
envsubst < tiles-worker.jsonc > wrangler.jsonc
wrangler deploy --env test

# Note that the "blah" bit is not used - the worker code expects it, but ignores it.
TEST_URL="https://${PMTILES_BUCKET}-test.${CLOUDFLARE_SUBDOMAIN}.workers.dev/blah"
LIVE_URL="https://${PMTILES_BUCKET}.${CLOUDFLARE_SUBDOMAIN}.workers.dev/blah"

# /14/8714/8016.mvt is Yaounde in Cameroon
# /14/8188/5448.mvt is around the Tower of London
# /14/8529/5974.mvt is Monaco
TARGETS="Monaco /14/8529/5974"
if [ "${AREA}" = "planet"]; then
    TARGETS="${TARGETS} Yaounde /14/8714/8016 TowerOfLondon /14/8188/5448"
fi

svclog "Test some downloads from the test domain ${TEST_URL}"
pmtiles-download-test pmtiles-test ${TEST_URL} ${TARGETS}

svclog "Cut over live worker too, and test that"
wrangler deploy --env live

pmtiles-download-test pmtiles-live ${LIVE_URL} ${TARGETS}
popd # leave wrangler

svclog "pmtiles job completed"
