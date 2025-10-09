#!/bin/bash
set -euo pipefail
. ${BASE}/env.sh # We reload env.sh, as the previous script may have added to it
. ${BASE}/utils.sh

svclog "Extracts job starting"

svclog "Creating R2 bucket"
pushd ${BASE}/wrangler
# Create the R2 bucket if it doesn't exist already
sed -e "s/R2_BUCKET/${EXTRACTS_BUCKET}/g" r2.jsonc > wrangler.jsonc
wrangler r2 bucket info ${EXTRACTS_BUCKET} || wrangler r2 bucket create ${EXTRACTS_BUCKET}
popd

# VENV commented out - does not seem that we need it.
#. ${BASE}/venv/bin/activate
pushd ${DATADIR}/planetiler-openmaptiles/soundscape-maps

# Run the python script which will use the stock world_countries_and_city_groups.geojson which
# is now in git.
# xxx FIXME: this sed stuff is nonsense.
svclog "Build extracts - may take a while"
sed -i 's|\./pmtiles|pmtiles|g' step2-generate-extracts-from-geojson.py
python step2-generate-extracts-from-geojson.py \
    --input-tiles ${DATADIR}/${PMTILESFILE} \
    --outdir ${DATADIR}/extracts \
    --output-geojson ${DATADIR}/extracts/manifest.geojson

# Gzip the manifest once.
gzip ${DATADIR}/extracts/manifest.geojson

cd ${DATADIR}/extracts

# Upload the extracts to R2
svclog "Copying to R2"
rclone copy ${DATADIR}/extracts r2:${EXTRACTS_BUCKET}/${DATESTAMP} \
        --progress \
        --s3-upload-concurrency 32 \
        --s3-chunk-size 64M \
        --transfers 32 \
        --retries 10 \
        --low-level-retries 20

# xxx FIXME: cut over R2 routes - not implemented yet.

# Return to wherever we started
#. ${BASE}/bin/deactivate
popd
svclog "Extracts job completed"
