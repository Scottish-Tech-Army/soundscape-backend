#!/bin/bash
# Set up DNS zone and AFD configuration for the links site
set -euo pipefail

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."
# cfgutils sources shared-cfg.sh (providing SHAREDRG, FRONTDOOR, DNS_SUFFIX)
# and handles az account set
. scripts/cfgutils.sh

echo "SHAREDRG: ${SHAREDRG}"

ZONE_NAME="links.${DNS_SUFFIX}"
AFD_ENDPOINT_NAME="links-ep"
AFD_CUSTOM_DOMAIN_NAME="links"
AFD_ORIGIN_GROUP_NAME="links-og"
AFD_ORIGIN_NAME="links-origin"
AFD_ROUTE_NAME="links-route"
AFD_RULESET_NAME="linksruleset"

# Derive info site hostname and path from INFOSITE config variable
INFOSITE_NO_SCHEME=${INFOSITE#https://}
INFOSITE_HOST=${INFOSITE_NO_SCHEME%%/*}
INFOSITE_PATH=/${INFOSITE_NO_SCHEME#*/}
# Strip trailing slash from path (AFD adds it)
INFOSITE_PATH=${INFOSITE_PATH%/}

# Derive storage static website hostname from the storage account
STORAGE_WEB_URL=$(az storage account show \
    --name ${LINKSSTORAGENAME} \
    --resource-group ${LINKSRG} \
    --query "primaryEndpoints.web" -o tsv)
STORAGE_WEB_HOST=${STORAGE_WEB_URL#https://}
STORAGE_WEB_HOST=${STORAGE_WEB_HOST%/}
echo "Storage web hostname: ${STORAGE_WEB_HOST}"

# DNS zone (created as child of parent zone; NS delegation is handled automatically)
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

# AFD endpoint
if az afd endpoint show \
    -g ${SHAREDRG} \
    --profile-name ${FRONTDOOR} \
    -n ${AFD_ENDPOINT_NAME} \
    >/dev/null 2>&1
then
    echo "AFD endpoint ${AFD_ENDPOINT_NAME} already exists"
else
    echo "Creating AFD endpoint ${AFD_ENDPOINT_NAME}"
    az afd endpoint create \
        -g ${SHAREDRG} \
        --profile-name ${FRONTDOOR} \
        -n ${AFD_ENDPOINT_NAME} \
        --enabled-state Enabled
fi

# AFD custom domain (ManagedCertificate; auto-validated via Azure DNS in same subscription)
if az afd custom-domain show \
    -g ${SHAREDRG} \
    --profile-name ${FRONTDOOR} \
    -n ${AFD_CUSTOM_DOMAIN_NAME} \
    >/dev/null 2>&1
then
    echo "AFD custom domain ${AFD_CUSTOM_DOMAIN_NAME} already exists"
else
    echo "Creating AFD custom domain ${AFD_CUSTOM_DOMAIN_NAME}"
    az afd custom-domain create \
        -g ${SHAREDRG} \
        --profile-name ${FRONTDOOR} \
        -n ${AFD_CUSTOM_DOMAIN_NAME} \
        --host-name ${ZONE_NAME} \
        --certificate-type ManagedCertificate
fi

# AFD origin group
# Health probe uses /.well-known/health — a trivial static file that returns 200.
if az afd origin-group show \
    -g ${SHAREDRG} \
    --profile-name ${FRONTDOOR} \
    -n ${AFD_ORIGIN_GROUP_NAME} \
    >/dev/null 2>&1
then
    echo "AFD origin group ${AFD_ORIGIN_GROUP_NAME} already exists"
else
    echo "Creating AFD origin group ${AFD_ORIGIN_GROUP_NAME}"
    az afd origin-group create \
        -g ${SHAREDRG} \
        --profile-name ${FRONTDOOR} \
        -n ${AFD_ORIGIN_GROUP_NAME} \
        --sample-size 4 \
        --successful-samples-required 3 \
        --additional-latency-in-milliseconds 0 \
        --probe-path "/.well-known/health" \
        --probe-protocol Https \
        --probe-interval-in-seconds 100 \
        --probe-request-type GET
fi

# AFD origin pointing to the storage static website endpoint
if az afd origin show \
    -g ${SHAREDRG} \
    --profile-name ${FRONTDOOR} \
    --origin-group-name ${AFD_ORIGIN_GROUP_NAME} \
    -n ${AFD_ORIGIN_NAME} \
    >/dev/null 2>&1
then
    echo "AFD origin ${AFD_ORIGIN_NAME} already exists"
else
    echo "Creating AFD origin ${AFD_ORIGIN_NAME}"
    az afd origin create \
        -g ${SHAREDRG} \
        --profile-name ${FRONTDOOR} \
        --origin-group-name ${AFD_ORIGIN_GROUP_NAME} \
        -n ${AFD_ORIGIN_NAME} \
        --host-name ${STORAGE_WEB_HOST} \
        --origin-host-header ${STORAGE_WEB_HOST} \
        --https-port 443 \
        --enabled-state Enabled
fi

# AFD rule set (a named container; rules are added below)
if az afd rule-set show \
    -g ${SHAREDRG} \
    --profile-name ${FRONTDOOR} \
    -n ${AFD_RULESET_NAME} \
    >/dev/null 2>&1
then
    echo "AFD rule set ${AFD_RULESET_NAME} already exists"
else
    echo "Creating AFD rule set ${AFD_RULESET_NAME}"
    az afd rule-set create \
        -g ${SHAREDRG} \
        --profile-name ${FRONTDOOR} \
        -n ${AFD_RULESET_NAME}
fi

# AFD route: accepts HTTP and HTTPS, redirects HTTP to HTTPS, forwards to storage origin.
# Caching is disabled. The rule set is applied to handle the redirect logic.
if az afd route show \
    -g ${SHAREDRG} \
    --profile-name ${FRONTDOOR} \
    --endpoint-name ${AFD_ENDPOINT_NAME} \
    -n ${AFD_ROUTE_NAME} \
    >/dev/null 2>&1
then
    echo "AFD route ${AFD_ROUTE_NAME} already exists"
else
    echo "Creating AFD route ${AFD_ROUTE_NAME}"
    az afd route create \
        -g ${SHAREDRG} \
        --profile-name ${FRONTDOOR} \
        --endpoint-name ${AFD_ENDPOINT_NAME} \
        -n ${AFD_ROUTE_NAME} \
        --enabled-state Enabled \
        --custom-domains ${AFD_CUSTOM_DOMAIN_NAME} \
        --supported-protocols Http Https \
        --https-redirect Enabled \
        --link-to-default-domain Disabled \
        --patterns-to-match "/*" \
        --origin-group ${AFD_ORIGIN_GROUP_NAME} \
        --forwarding-protocol HttpsOnly \
        --enable-caching false \
        --rule-sets ${AFD_RULESET_NAME}
fi

# Redirect rule: requests whose URL path does NOT begin with /.well-known/ are
# redirected (301) to the info site (INFOSITE in config). Requests for
# /.well-known/ (assetlinks.json, health) match no rule and pass through to origin.
if az afd rule show \
    -g ${SHAREDRG} \
    --profile-name ${FRONTDOOR} \
    --rule-set-name ${AFD_RULESET_NAME} \
    -n redirecttoinfosite \
    >/dev/null 2>&1
then
    echo "AFD rule redirecttoinfosite already exists"
else
    echo "Creating AFD rule redirecttoinfosite"
    az afd rule create \
        -g ${SHAREDRG} \
        --profile-name ${FRONTDOOR} \
        --rule-set-name ${AFD_RULESET_NAME} \
        --name redirecttoinfosite \
        --order 1 \
        --match-variable UrlPath \
        --operator BeginsWith \
        --negate-condition true \
        --match-values "/.well-known/" \
        --action-name UrlRedirect \
        --redirect-type Moved \
        --redirect-protocol Https \
        --custom-hostname "${INFOSITE_HOST}" \
        --custom-path "${INFOSITE_PATH}/"
fi

# DNS A record aliased to the AFD endpoint
TARGET="/subscriptions/${SUBSCRIPTION}/resourceGroups/${SHAREDRG}/providers/Microsoft.Cdn/profiles/${FRONTDOOR}/afdEndpoints/${AFD_ENDPOINT_NAME}"

if az network dns record-set a show \
    -g ${SHAREDRG} \
    -z ${ZONE_NAME} \
    -n "@" \
    >/dev/null 2>&1
then
    echo "DNS A record @ in ${ZONE_NAME} already exists"
else
    echo "Creating DNS A record @ in ${ZONE_NAME}"
    az network dns record-set a create \
        -g ${SHAREDRG} \
        -z ${ZONE_NAME} \
        -n "@" \
        --target-resource "${TARGET}"
fi

echo "SUCCESS"
