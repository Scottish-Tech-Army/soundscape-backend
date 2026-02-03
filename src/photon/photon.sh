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

# Login to the ACR, and pull the image for photon
az login --identity --client-id ${ACR_CLIENT_ID}
az acr login --name ${REGISTRY_NAME}
docker pull ${PHOTONIMAGE}

# For tedious reasons (ARM64 mostly) we need to build the docker image locally.
pushd ${BASE}/photon/health
export HEALTHIMAGE=health:latest
docker build -t ${HEALTHIMAGE} -f Dockerfile.health .
popd

svclog "Starting health image from ${HEALTHIMAGE}"
docker run -dit \
    --network host \
    --log-driver=json-file \
    --log-opt max-size=100m \
    --log-opt max-file=10 \
    --name health \
    --restart=unless-stopped \
    ${HEALTHIMAGE}

# Run the image
svclog "Starting photon server container from image ${PHOTONIMAGE}"
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
    ${PHOTONIMAGE}

svclog "Photon server started"

# Plumb in the logs
for i in health photon-server
do
    CONTAINER_ID=$(docker inspect --format='{{.Id}}' ${i})
    LOGPATH="/var/lib/docker/containers/${CONTAINER_ID}/${CONTAINER_ID}-json.log"
    sudo ln -s ${LOGPATH} ${BASE}/logs/${i}-json.log
    svclog "Log file symlinked to ${BASE}/logs/${i}-json.log"
done
