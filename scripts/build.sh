#!/bin/bash
# Script to build the container, and push it.
set -euo pipefail

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."

# Login to the ACR
az acr login -n ${REGISTRYNAME}

# Build the container locally, retag it, and push to the ACR
# Only tilesrv is still in use; others for historical reasons.
#for i in ingest_simple ingest_diffs tilesrv debug
for i in tilesrv
do
  echo "Building and pushing ${i} container"
  docker build Docker/ -t ${i} -f Docker/Dockerfile.${i}
  docker tag ${i}:latest ${REGISTRYNAME}.azurecr.io/soundscape/${i}:${VERSION}
  docker push ${REGISTRYNAME}.azurecr.io/soundscape/${i}:${VERSION}
done