#!/bin/bash
# Script to run some tests on the top level domains
set -euo pipefail

# This script should be run from the location where the outputs are to go, but it relies on files in the repo.

# This file takes a single argument, which can be "soundscape", "prd2", or "tst".
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 {soundscape|prd2|tst}"
    exit 1
fi

case "$1" in
    soundscape)
        DOMAIN="$1"
        TILESRV_APP_URL="https://soundscape.scottishtecharmy.org/tiles"
        ;;
    prd2)
        DOMAIN="$1"
        TILESRV_APP_URL="https://prd2.soundscape.scottishtecharmy.org/tiles"
        ;;
    tst)
        DOMAIN="$1"
        TILESRV_APP_URL="https://tst.soundscape.scottishtecharmy.org/tiles"
        ;;
    *)
        echo "Invalid argument: $1 - must be one of soundscape, prd2, tst"
        exit 1
        ;;
esac

export OUTDIR="$(pwd)/${DOMAIN}"
mkdir -p "${OUTDIR}"

LOGFILE="${OUTDIR}/${DOMAIN}_$(date +%Y%m%d_%H%M%S).log"

# Run through all the tests in order, sleeping 5 seconds after each one.
cd "$(dirname "$0")/.."
pushd /home/plw/work/soundscape/soundscape-backend/src/tiletest
python tiletest.py \
    --output ${OUTDIR} --shuffle \
    --base-url ${TILESRV_APP_URL} > ${LOGFILE} 2>&1
popd