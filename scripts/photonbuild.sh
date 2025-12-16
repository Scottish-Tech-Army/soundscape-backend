#!/bin/bash
# Script to build the container, and push it.
set -euo pipefail

# Change to the parent directory of the scripts directory and source utils.
cd "$(dirname "$0")/.."
. scripts/cfgutils.sh

# Login to the ACR
az acr login -n ${REGISTRYNAME}

# Pull the image to retag and push
SRCIMAGE=rtuszik/photon-docker:latest
DESTIMAGE=${REGISTRYNAME}.azurecr.io/photon/photon-docker:${VERSION}

docker pull --platform linux/arm64 ${SRCIMAGE}
docker tag ${SRCIMAGE} ${DESTIMAGE}
docker push ${DESTIMAGE}
