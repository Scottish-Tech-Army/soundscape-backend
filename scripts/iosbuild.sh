#!/bin/bash
# Script to build the container, and push it.
set -euo pipefail

# Change to the parent directory of the scripts directory and source utils.
cd "$(dirname "$0")/.."
. scripts/cfgutils.sh

# Login to the ACR
az acr login -n ${REGISTRYNAME}

# Build the container locally, retag it, and push to the ACR
# Only tilesrv is still in use; others for historical reasons.
#for i in ingest_diffs tilesrv debug
for i in tilesrv
do
  echo "Building and pushing ${i} container"
  docker build src/${i} -t ${i} -f src/${i}/Dockerfile.${i}
  docker tag ${i}:latest ${REGISTRYNAME}.azurecr.io/soundscape/${i}:${VERSION}
  docker push ${REGISTRYNAME}.azurecr.io/soundscape/${i}:${VERSION}
done