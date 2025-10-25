#!/bin/bash
set -euo pipefail
. ${BASE}/utils.sh

# DATESTAMP is a string something like "20251023-1513"
export DATESTAMP=$(date +%Y%m%d-%H%M)
export PMTILESFILE=${AREA}-$(DATESTAMP).pmtiles
echo "export PMTILESFILE=${PMTILESFILE}" >> ${BASE}/env.sh
echo "export DATESTAMP=${DATESTAMP}" >> ${BASE}/env.sh

svclog "pmtiles job starting, for area ${AREA}, output ${PMTILESFILE}"

svclog "Creating R2 bucket"
pushd ${BASE}/wrangler
# Create the R2 bucket if it doesn't exist already
export R2_BUCKET=${PMTILES_BUCKET}
envsubst < r2.jsonc > wrangler.jsonc
wrangler r2 bucket info ${PMTILES_BUCKET} || wrangler r2 bucket create ${PMTILES_BUCKET}
popd

svclog "Setting up the code"
# Clone the repo with scripts
pushd ${DATADIR}
git clone https://github.com/davecraig/planetiler-openmaptiles.git

# Build the code and set everything up ready to download and build the map.
svclog "Download map data"
cd planetiler-openmaptiles
bash scripts/regenerate-openmaptiles.sh

# Build the map. Note that the "-f" option is required to avoid the tooling trying to download from AWS.
svclog "Build the map - may take a while"
cd soundscape-maps
bash build-map.sh ${AREA}

# Rename the map produced
svclog "Build completed - wrap up"
ln map-to-serve/${AREA}.pmtiles ${DATADIR}/${PMTILESFILE}

# Use rclone to copy the data to blob store.
svclog "Copying to blob store - may take a while"
rclone copy ${DATADIR}/${PMTILESFILE} blob:${PMTILES_BUCKET}/${DATESTAMP} \
        --progress \
        --s3-upload-concurrency 32 \
        --s3-chunk-size 64M \
        --transfers 32 \
        --retries 10 \
        --low-level-retries 20

# Now pull the data across using some cunning worker code.
svclog "Cut data across using streaming worker - around half a minute per GB, so this is slow"
pushd ${BASE}/wrangler
export TILES_URL="https://${EXTRACTS_STORAGE_ACCOUNT}.blob.core.windows.net/${PMTILES_BUCKET}"
envsubst < extracts-worker.jsonc > wrangler.jsonc
wrangler deploy
export WORKER_SUBDOMAIN=$(wrangler whoami | awk '{print $3}')
curl --fail-with-body https://${PMTILES-BUCKET}-stream/${CLOUDFLARE_SUBDOMAIN}.workers.dev/${PMTILESFILE}?nodata
popd

svclog "Build the code"
cd ${DATADIR}
git clone https://github.com/protomaps/PMTiles.git
cd PMTiles/serverless/cloudflare
npm i pmtiles
npx esbuild src/index.ts --bundle --format=esm --outfile=dist/index.js
mv dist ${BASE}/wrangler/

svclog "Cut over worker to use ${PMTILESFILE}"
export PMTILES_PATH=${PMTILESFILE} # Variable used by tiles-worker.jsonc
pushd ${BASE}/wrangler
envsubst < tiles-worker.jsonc > wrangler.jsonc
wrangler deploy --env test
echo "Should do testing here - not implemented yet"
wrangler deploy --env live
popd

# Return to wherever we started
popd
svclog "pmtiles job completed"
