#!/bin/bash
# Set up shared DNS zone and plumb it all into AFD
set -euo pipefail
echo "SHAREDRG: ${SHAREDRG}"

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."
# Check we are logged into the correct subscription
az account set --subscription ${SUBSCRIPTION}

# Retrieve the base domain and endpoint type from the parameters
if [[ $# -ne 2 ]]
then
  echo "Usage: $0 <BASE_DOMAIN> <ENDPOINT_TYPE>"
  echo "  where BASE_DOMAIN is the alphanumeric prefix for the shared zone"
  echo "  and ENDPOINT_TYPE is either 'ios' or 'photon'"
  exit 1
fi

BASE_DOMAIN=$1
ENDPOINT_TYPE=$2

if [[ ! "$BASE_DOMAIN" =~ ^[a-zA-Z0-9]+$ ]]; then
  echo "Error: base_domain must contain only letters and numbers."
  exit 1
fi

if [[ "$ENDPOINT_TYPE" != "ios" && "$ENDPOINT_TYPE" != "photon" ]]; then
  echo "Error: ENDPOINT_TYPE must be either 'ios' or 'photon'."
  exit 1
fi

BASE_DOMAIN=${BASE_DOMAIN,,} # convert to lowercase

if [[ ! "$1" =~ ^[a-zA-Z0-9]+$ ]]; then
  echo "Error: base_domain must contain only letters and numbers."
  exit 1
fi

DNS_SUFFIX="soundscape.scottishtecharmy.org"  # fixed suffix

ZONE_NAME="${BASE_DOMAIN}.${DNS_SUFFIX}"

echo "Creating DNS zone and AFD infra ${ZONE_NAME} in RG ${SHAREDRG}"
echo

AFD_ENDPOINT_NAME="${BASE_DOMAIN}-ep"
AFD_CUSTOM_DOMAIN_NAME="${BASE_DOMAIN}-cd"
AFD_ROUTE_NAME="${BASE_DOMAIN}-route"

# DNS zone
if az network dns zone show \
    -g ${SHAREDRG} \
    -n ${ZONE_NAME} \
    >/dev/null 2>&1
then
    echo "DNS zone ${ZONE_NAME} already exists"
else
    echo "Creating DNS zone ${ZONE_NAME}"
    az network dns zone create \
      -g ${SHAREDRG} \
      -n ${ZONE_NAME} \
      --parent-name ${DNS_SUFFIX}
fi

# AFD Endpoint; logical place that the zone will point at
if az afd endpoint show \
    -g ${SHAREDRG} \
    --profile-name "${FRONTDOOR}" \
    -n "${AFD_ENDPOINT_NAME}" \
    >/dev/null 2>&1
then
  echo "AFD endpoint ${AFD_ENDPOINT_NAME} already exists"
else
  echo "Creating AFD endpoint ${AFD_ENDPOINT_NAME}"
  az afd endpoint create \
    -g ${SHAREDRG} \
    --profile-name "${FRONTDOOR}" \
    -n "${AFD_ENDPOINT_NAME}" \
    --enabled-state Enabled
fi

# AFD custom domain
if az afd custom-domain show \
    -g ${SHAREDRG} \
    --profile-name ${FRONTDOOR} \
    -n ${BASE_DOMAIN} \
    >/dev/null 2>&1
then
  echo "AFD custom domain ${AFD_CUSTOM_DOMAIN_NAME} already exists"
else
  echo "Creating AFD custom domain ${AFD_CUSTOM_DOMAIN_NAME}"
  az afd custom-domain create \
    -g ${SHAREDRG} \
    --profile-name ${FRONTDOOR} \
    -n ${BASE_DOMAIN} \
    --host-name ${ZONE_NAME} \
    --certificate-type ManagedCertificate
fi

if [[ "$ENDPOINT_TYPE" == "ios" ]]; then
  PATTERN="tiles"
else
  PATTERN="photon"
fi

# AFD route; created pointing to the dummy origin, but can be updated later
if az afd route show \
    -g ${SHAREDRG} \
    --profile-name "${FRONTDOOR}" \
    --endpoint-name "${AFD_ENDPOINT_NAME}" \
    -n "${AFD_ROUTE_NAME}" \
    >/dev/null 2>&1
then
  echo "AFD route ${AFD_ROUTE_NAME} already exists"
else
  echo "Creating AFD route ${AFD_ROUTE_NAME}"
  az afd route create \
    -g ${SHAREDRG} \
    --profile-name "${FRONTDOOR}" \
    --endpoint-name "${AFD_ENDPOINT_NAME}" \
    -n "${AFD_ROUTE_NAME}" \
    --enabled-state Enabled \
    --custom-domains "${BASE_DOMAIN}" \
    --supported-protocols Https \
    --https-redirect Disabled \
    --enable-compression true \
    --enable-caching true \
    --query-string-caching-behavior UseQueryString \
    --link-to-default-domain Disabled \
    --patterns-to-match "/${PATTERN}/*" \
    --origin-path "/" \
    --origin-group dummy-blackhole
fi

# DNS A record
TARGET="/subscriptions/${SUBSCRIPTION}/resourceGroups/${SHAREDRG}/providers/Microsoft.Cdn/profiles/${FRONTDOOR}/afdEndpoints/${AFD_ENDPOINT_NAME}"

if az network dns record-set a show \
    -g ${SHAREDRG} \
    -z ${ZONE_NAME} \
    -n "@" \
    >/dev/null 2>&1
then
    echo "DNS A record @ in ${ZONE_NAME} already exists"
else
    echo "Creating DNS A record @ in ${ZONE_NAME} -> ${TARGET}"
    az network dns record-set a create \
    -g ${SHAREDRG} \
    -z ${ZONE_NAME} \
    -n "@" \
    --target-resource "${TARGET}"
fi

echo "SUCCESS"