#!/bin/bash
# Set up photon Front door origin group.
set -euo pipefail
echo "RG: ${RG}"

# Change to the parent directory of the scripts directory and source utils.
cd "$(dirname "$0")/.."
. scripts/cfgutils.sh

echo "Checking if origin group ${RG} exists"

# Note that the origin group is named matching the RG, but is in the SHARED RG.
if az afd origin-group show \
    --resource-group ${SHAREDRG} \
    --profile-name ${FRONTDOOR} \
    --origin-group-name ${RG} > /dev/null 2>&1
then
    echo "Origin group ${RG} already exists - giving up now"
    exit 1
else
    echo "Origin group ${RG} does not already exist - creating it"
fi

# Get the FQDN of the load balancer public IP.
PHOTONLBFQDN=$(az network public-ip show \
  --resource-group "$RG" \
  --name "${PREFIX}-publicip" \
  --query "dnsSettings.fqdn" \
  --output tsv)
echo "Photon load balancer FQDN: ${PHOTONLBFQDN}"


# Create the origin group that points to the container app
echo "Create origin group for Front Door"
az deployment group create \
    --resource-group ${SHAREDRG} \
    --template-file templates/origin.bicep \
    --parameters originGroupName=${RG} \
                 fdName=${FRONTDOOR} \
                 probePath="/" \
                 targetFQDN=${PHOTONLBFQDN} \
                 isHTTPS="false" \
                 port=2322

echo "SUCCESS"