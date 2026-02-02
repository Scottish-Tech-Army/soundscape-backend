#!/bin/bash
# Set up android infrastructure and run everything
set -euo pipefail
ENVFILE="$(dirname "$0")/env.sh"
. ${ENVFILE}
. ${BASE}/utils.sh

# Wait 30 seconds - AMA is already running, but takes a little while to be ready
sleep 30

LOGFILE="${BASE}/logs/photon_$(date +%Y%m%d_%H%M%S).log"
svclog "Ensuring that photon server is started - output to ${LOGFILE}"

if docker ps --format '{{.Names}}' | grep -qx "photon-server"
then
    svclog "Photon server container already running - drop out"
    exit 0
fi

# Login to the ACR, and pull the image
az login --identity --client-id ${ACR_CLIENT_ID}
az acr login --name ${REGISTRY_NAME}
docker pull ${IMAGE}

# Run the image
docker run -dit \
    -p 2322:2322 \
    -e UPDATE_STRATEGY=DISABLED \
    -e UPDATE_INTERVAL=30d \
    -e LOG_LEVEL=INFO \
    -e BASE_URL=https://download1.graphhopper.com/public/ \
    -e INITIAL_DOWNLOAD=TRUE \
    -e REGION=${AREA} \
    --log-driver=json-file \
    --log-opt max-size=100m \
    --log-opt max-file=10 \
    -v ${DATADIR}:/photon/data \
    --name photon-server \
    --restart=unless-stopped \
    ${IMAGE}

svclog "Photon server started"

# Plumb in the logs
CONTAINER_ID=$(docker inspect --format='{{.Id}}' photon-server)
LOGPATH="/var/lib/docker/containers/${CONTAINER_ID}/${CONTAINER_ID}-json.log"
sudo ln -s ${LOGPATH} ${BASE}/logs

svclog "Log file symlinked to ${BASE}/logs/${CONTAINER_ID}-json.log"

