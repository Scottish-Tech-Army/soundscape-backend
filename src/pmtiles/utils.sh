# Service log utility function
svclog() {
    # %F is YYYY-MM-DD, %T is HH:MM:SS
    #printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "${BASE}/logs/svc-${HOSTNAME}.log"
    # ISO 8601 format
    printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%S.%3NZ')" "$*" | tee -a "${BASE}/logs/svc-${HOSTNAME}.log"
}

redate () {
    # Convert a timestamp from "YYYY-MM-DD HH:MM:SS" to "YYYY-MM-DDTHH:MM:SSZ" format
    sed -E 's/^([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}:[0-9]{2}:[0-9]{2}) /\1T\2Z /'
}

pmtiles-download-test() {
    # Issues test requests, and sanity checks the responses
    # Arguments:
    # - directory name (not a full path - will be nuked and recreated)
    # - URL base; no trailing slash
    # - List of URL paths and names (pairs; paths must be leading slash, no .mvt suffix, while names are single word)
    local DIRNAME="${DATADIR}/pmtiles-download-test/$1"
    local URLBASE="$2"
    shift 2

    # This sleep is because right after setting up a worker, sometimes it takes a few seconds
    # for it to be ready, and we want to make sure that we get the latest data.
    echo "Sleep 90 seconds for worker to be ready for pmtiles test"
    sleep 90

    echo "Nuking and recreating test directory ${DIRNAME}"
    rm -rf "${DIRNAME}"
    mkdir -p "${DIRNAME}"
    pushd "${DIRNAME}"

    while [ $# -gt 1 ]; do
        local NAME=$1
        local URLPATH=$2
        echo "$NAME $URLPATH"
        shift 2

        local URL="${URLBASE}${URLPATH}.mvt"
        echo "Tile download of ${URL}"
        curl -D - --fail-with-body ${URL} -o ${NAME}.mvt
        echo "Validation of file ${NAME}.mvt"
        ogrinfo ${NAME}.mvt
    done

    popd
}

extracts-download-test() {
    # Test that the extracts can be downloaded successfully
    # Arguments:
    # - directory name (not a full path - will be nuked and recreated)
    # - URL base; no trailing slash
    local DIRNAME="${DATADIR}/extracts-download-test/$1"
    local URLBASE="$2"

    mkdir -p $DATADIR/extracts-test
    pushd $DATADIR/extracts-test

    # This sleep is because right after setting up a worker, sometimes it takes a few seconds
    # for it to be ready, and we want to make sure that we get the latest data.
    echo "Sleep 90 seconds for worker to be ready for extracts test"
    sleep 90

    curl -D - --fail-with-body "${URLBASE}/manifest.geojson.gz" -o manifest.geojson.gz

    diff manifest.geojson.gz $DATADIR/extracts/manifest.geojson.gz

    FILELIST=$(find ${DATADIR}/extracts -name "*.pmtiles" | shuf -n 3)
    for f in ${FILELIST}; do
        FILENAME=$(basename $f)
        echo "Testing extract ${URLBASE}/${FILENAME}"
        curl -D - --fail-with-body "${URLBASE}/${FILENAME}?nodata"
    done
    popd # Done with testing
}