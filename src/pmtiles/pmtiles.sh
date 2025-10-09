#!/bin/bash
set -euo pipefail
. ${BASE}/utils.sh

export DATESTAMP=$(date +%Y%m%d-%H%M)
export PMTILESFILE=${AREA}-$(DATESTAMP).pmtiles
echo "export PMTILESFILE=${PMTILESFILE}" >> ${BASE}/env.sh
echo "export DATESTAMP=${DATESTAMP}" >> ${BASE}/env.sh

svclog "pmtiles job starting, for area ${AREA}, output ${PMTILESFILE}"

svclog "Creating R2 bucket"
pushd ${BASE}/wrangler
# Create the R2 bucket if it doesn't exist already
sed -e "s/R2_BUCKET/${PMTILES_BUCKET}/g" r2.jsonc > wrangler.jsonc
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

# Use rclone to copy the data to R2. This can take a while.
svclog "Copying to R2 - may take a while"
rclone copy ${DATADIR}/${PMTILESFILE} r2:${PMTILES_BUCKET} \
        --progress \
        --s3-upload-concurrency 32 \
        --s3-chunk-size 64M \
        --transfers 32 \
        --retries 10 \
        --low-level-retries 20

svclog "Build the code"
cd ${DATADIR}
git clone https://github.com/protomaps/PMTiles.git
cd PMTiles/serverless/cloudflare
npm i pmtiles
npx esbuild src/index.ts --bundle --format=esm --outfile=dist/index.js
mv dist ${BASE}/wrangler/

svclog "Cut over worker to use ${PMTILESFILE}"
export PMTILES_PATH=${PMTILESFILE} # Variable used by worker.jsonc
pushd ${BASE}/wrangler
# R2 bucket names cannot be interpolated, so we use sed to copy it in.
sed -e "s/R2_BUCKET/${PMTILES_BUCKET}/g" worker.jsonc > wrangler.jsonc
wrangler deploy --env test
echo "Should do testing here - not implemented yet"
wrangler deploy --env live
popd

# Return to wherever we started
popd
svclog "pmtiles job completed"
