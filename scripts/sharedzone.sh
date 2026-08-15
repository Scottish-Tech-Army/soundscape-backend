#!/bin/bash
# Set up a shared DNS record and plumb it all into AFD
#
# Usage:  bash scripts/sharedzone.sh {prd2|tst|photon|photontest}
set -euo pipefail

# Retrieve the base domain from the parameter. There are only four shared
# domains, and which service each one fronts is a fixed fact about it, so the
# endpoint type is derived here rather than passed in as a second argument
# that could only ever contradict the first.
if [[ $# -ne 1 ]]
then
  echo "Usage: $0 <BASE_DOMAIN>" >&2
  echo "  where BASE_DOMAIN is one of 'prd2', 'tst', 'photon' or 'photontest'" >&2
  exit 1
fi

BASE_DOMAIN="${1,,}" # lowercase

case "${BASE_DOMAIN}" in
  prd2|tst)          ENDPOINT_TYPE="ios" ;;
  photon|photontest) ENDPOINT_TYPE="photon" ;;
  *)
    echo "Error: BASE_DOMAIN must be one of 'prd2', 'tst', 'photon' or 'photontest' (got '$1')" >&2
    exit 1
    ;;
esac

echo "SHAREDRG: ${SHAREDRG}"

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."
# Check we are logged into the correct subscription
az account set --subscription ${SUBSCRIPTION}

. scripts/zoneutils.sh

echo "Setting up AFD infra for ${BASE_DOMAIN}.${DNS_SUFFIX} in RG ${SHAREDRG}"
echo

AFD_ENDPOINT_NAME="${BASE_DOMAIN}-ep"
AFD_ROUTE_NAME="${BASE_DOMAIN}-route"

# AFD endpoint and custom domain
ensure_endpoint_and_domain "${BASE_DOMAIN}"

if [[ "$ENDPOINT_TYPE" == "ios" ]]; then
  FWDPROTOCOL="" # No forwarding protocol; keep protocol as is
  PATTERN="tiles"
else
  FWDPROTOCOL="--forwarding-protocol HttpOnly"
  PATTERN="photon"
fi

# Content types the route compresses. The cdn CLI extension takes cache settings
# as a single structured --cache-configuration argument and supplies no defaults,
# so this is the list that the retired --enable-compression flag used to fill in
# on our behalf. It is spelled out rather than left empty because an enabled-but-
# empty list compresses nothing: dropping it would silently stop compressing on
# every route created from here on, while leaving existing routes compressing.
AFD_COMPRESS_TYPES="\
application/eot,application/font,application/font-sfnt,application/javascript,\
application/json,application/opentype,application/otf,application/pkcs7-mime,\
application/truetype,application/ttf,application/vnd.ms-fontobject,application/xhtml+xml,\
application/xml,application/xml+rss,application/x-font-opentype,application/x-font-truetype,\
application/x-font-ttf,application/x-httpd-cgi,application/x-javascript,application/x-mpegurl,\
application/x-opentype,application/x-otf,application/x-perl,application/x-ttf,\
font/eot,font/ttf,font/otf,font/opentype,\
image/svg+xml,text/css,text/csv,text/html,\
text/javascript,text/js,text/plain,text/richtext,\
text/tab-separated-values,text/xml,text/x-script,text/x-component,\
text/x-java-source"

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
    --formatted-custom-domains "[{id:$(afd_resource_id customDomains "${BASE_DOMAIN}")}]" \
    --supported-protocols Https \
    --https-redirect Disabled \
    --cache-configuration "{query-string-caching-behavior:UseQueryString,compression-settings:{is-compression-enabled:true,content-types-to-compress:[${AFD_COMPRESS_TYPES}]}}" \
    --link-to-default-domain Disabled \
    ${FWDPROTOCOL} --patterns-to-match "/${PATTERN}/*" \
    --origin-path "/" \
    --origin-group dummy-blackhole
fi

# DNS CNAME alias record, in the parent zone, pointing at the AFD endpoint
ensure_dns_alias "${BASE_DOMAIN}"

echo "SUCCESS"
