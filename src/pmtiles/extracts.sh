#!/bin/bash
set -euo pipefail
. ${BASE}/env.sh # We reload env.sh, as the previous script may have added to it
. ${BASE}/utils.sh

svclog "Extracts job starting"

svclog "Creating R2 bucket and queues"
pushd ${BASE}/wrangler
# Create the R2 bucket if it doesn't exist already
export R2_BUCKET=${EXTRACTS_BUCKET}
envsubst < r2.jsonc > wrangler.jsonc
wrangler r2 bucket info ${EXTRACTS_BUCKET} || wrangler r2 bucket create ${EXTRACTS_BUCKET} --location weur

wrangler queues info ${EXTRACTS_BUCKET} || wrangler queues create ${EXTRACTS_BUCKET}
wrangler queues info ${EXTRACTS_BUCKET}-test || wrangler queues create ${EXTRACTS_BUCKET}-test
popd

pushd ${DATADIR}/planetiler-openmaptiles/soundscape-maps

# Run the python script which will use the stock world_countries_and_city_groups.geojson which
# is now in git.
# xxx FIXME: this sed stuff is nonsense.
svclog "Build extracts - may take 20 minutes or so for world"
sed -i 's|\./pmtiles|pmtiles|g' step2-generate-extracts-from-geojson.py
python step2-generate-extracts-from-geojson.py \
    --input-tiles ${DATADIR}/${PMTILESFILE} \
    --outdir ${DATADIR}/extracts \
    --output-geojson ${DATADIR}/extracts/manifest.geojson \
    --prefix "${DATESTAMP}-"

# Gzip the manifest once.
gzip ${DATADIR}/extracts/manifest.geojson

cd ${DATADIR}/extracts

# List contents of the extracts directory.
echo "Contents of ${DATADIR}/extracts:"
ls -lh ${DATADIR}/extracts || true
df -h || true
du -sh ${DATADIR}/* || true

# Upload all of the extracts to blob storage
svclog "Copying to blob"
rclone copy ${DATADIR}/extracts blob:${EXTRACTS_BUCKET}/${DATESTAMP} \
        --progress \
        --s3-upload-concurrency 32 \
        --s3-chunk-size 64M \
        --transfers 32 \
        --retries 10 \
        --low-level-retries 20

svclog "Cut over worker to use extracts from ${DATESTAMP}"
pushd ${BASE}/wrangler
export EXTRACTS_URL="https://${TRANSFER_STORAGE_ACCOUNT}.blob.core.windows.net/${EXTRACTS_BUCKET}"

envsubst < extracts-queue.jsonc > wrangler.jsonc
wrangler deploy --env test

envsubst < extracts-worker.jsonc > wrangler.jsonc
wrangler deploy --env test

svclog "Test that the extracts work"
URLBASE="https://${EXTRACTS_BUCKET}-test.${CLOUDFLARE_SUBDOMAIN}.workers.dev"
extracts-download-test test $URLBASE

# Kick off the download of some large extracts we are sure will be used, to reduce the risk of queues being blocked.
svclog "Kick off large extract download to warm cache; ignore result"
for i in belgium united-kingdom france
do
    echo "Download of large extract ${i}"
    curl -D - "${URLBASE}/${DATESTAMP}-${i}.pmtiles?nodata" -o /dev/null || true
done
# We strictly do not NEED to sleep here, but it's not a bad idea to wait until the large extracts are
# in R2 or at least approaching completion before we cut over.
sleep 120

svclog "Promote worker to live and retest"
envsubst < extracts-queue.jsonc > wrangler.jsonc
wrangler deploy --env live

envsubst < extracts-worker.jsonc > wrangler.jsonc
wrangler deploy --env live

URLBASE="https://${EXTRACTS_BUCKET}.${CLOUDFLARE_SUBDOMAIN}.workers.dev"
extracts-download-test live $URLBASE
popd # leave wrangler

# Return to wherever we started
popd
svclog "Extracts job completed"
