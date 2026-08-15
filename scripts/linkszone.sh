#!/bin/bash
# Set up DNS and AFD configuration for a links-site label: either the live
# "links" domain or the "linkstest" test domain, which share the same Front
# Door profile and storage origin.
#
# Usage:  bash scripts/linkszone.sh {links|linkstest}
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: bash scripts/linkszone.sh {links|linkstest}" >&2
  exit 1
fi

# Check the label provided.
LABEL="${1,,}" # lowercase
case "${LABEL}" in
  links|linkstest) ;;
  *)
    echo "Error: label must be 'links' or 'linkstest' (got '$1')" >&2
    exit 1
    ;;
esac

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."
# cfgutils sources shared-cfg.sh (providing SHAREDRG, FRONTDOOR, DNS_SUFFIX)
# and handles az account set
. scripts/cfgutils.sh
. scripts/zoneutils.sh

echo "SHAREDRG: ${SHAREDRG}"

AFD_ENDPOINT_NAME="${LABEL}-ep"
AFD_ORIGIN_GROUP_NAME="${LABEL}-og"
AFD_ORIGIN_NAME="${LABEL}-origin"
AFD_ROUTE_NAME="${LABEL}-route"
AFD_RULESET_NAME="${LABEL}ruleset"

echo "Setting up AFD infra for ${LABEL}.${DNS_SUFFIX} in RG ${SHAREDRG}"

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

# AFD endpoint and custom domain
ensure_endpoint_and_domain "${LABEL}"

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
# Caching is disabled (the default). The rule set is applied to handle the redirect logic.
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
        --formatted-custom-domains "[{id:$(afd_resource_id customDomains "${LABEL}")}]" \
        --supported-protocols Http Https \
        --https-redirect Enabled \
        --link-to-default-domain Disabled \
        --patterns-to-match "/*" \
        --origin-group ${AFD_ORIGIN_GROUP_NAME} \
        --forwarding-protocol HttpsOnly \
        --formatted-rule-sets "[{id:$(afd_resource_id ruleSets "${AFD_RULESET_NAME}")}]"
fi

# Redirect rule: requests whose URL path does NOT begin with /.well-known/ are
# redirected (301) to the info site (INFOSITE in config). Requests for
# /.well-known/ (assetlinks.json, health) match no rule and pass through to origin.
#
# The condition and action are given in the cdn extension's shorthand syntax
# (https://aka.ms/cli-shorthand): the extension has no flat --match-variable /
# --action-name flags, only these two structured arguments. Values interpolated
# from config are single-quoted so a "/" or "." in them cannot be read as
# shorthand punctuation.
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
        --conditions "[{url-path:{parameters:{operator:BeginsWith,negate-condition:true,match-values:['/.well-known/']}}}]" \
        --actions "[{url-redirect:{parameters:{redirect-type:Moved,destination-protocol:Https,custom-hostname:'${INFOSITE_HOST}',custom-path:'${INFOSITE_PATH}/'}}}]"
fi

# DNS CNAME alias record, in the parent zone, pointing at the AFD endpoint
ensure_dns_alias "${LABEL}"

echo "SUCCESS"
