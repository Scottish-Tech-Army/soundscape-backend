#!/bin/bash
# Set up shared RG
set -euo pipefail
echo "SHAREDRG: ${SHAREDRG}"

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."
# Check we are logged into the correct subscription
az account set --subscription ${SUBSCRIPTION}

# Source the diags config file
. config/diags-cfg.sh

# Create the group
az group create --location ${SHAREDREGION} --resource-group ${SHAREDRG}

echo "Deploying shared resource group"
az deployment group create \
    --resource-group ${SHAREDRG} \
    --template-file templates/sharedbase.bicep \
    --parameters registryName=${REGISTRYNAME} \
                 uamiName=${REGISTRYUAMI} \
                 sharedLAW=${SHAREDLAW} \
                 certAlertUamiName=${CERT_ALERT_UAMI}

# Check if the Front Door profile exists, and if not create it
if az afd profile show --resource-group ${SHAREDRG} --profile-name ${FRONTDOOR} >/dev/null 2>&1
then
    echo "Front Door profile ${FRONTDOOR} already exists in RG ${SHAREDRG}"
else
    echo "Creating Front Door profile ${FRONTDOOR} in RG ${SHAREDRG}"

    az afd profile create \
        --resource-group ${SHAREDRG} \
        --profile-name ${FRONTDOOR} \
        --sku Standard_AzureFrontDoor
fi

# Create diagnostic settings
LAW_ID=$(az monitor log-analytics workspace show --name "${SHAREDLAW}" --resource-group ${SHAREDRG} --query id -o tsv)
if az monitor diagnostic-settings show \
        --name afd-logs \
        --resource "${FRONTDOOR}" \
        --resource-group "${SHAREDRG}" \
        --resource-type "Microsoft.Cdn/profiles" >/dev/null 2>&1
then
    echo "Diagnostic setting afd-logs already exists. No action taken."
else
    echo "Creating diagnostic setting afd-logs"
    az monitor diagnostic-settings create \
        --name afd-logs \
        --resource "${FRONTDOOR}" \
        --resource-type "Microsoft.Cdn/profiles" \
        --resource-group "${SHAREDRG}" \
        --workspace "${LAW_ID}" \
        --logs '[
            {"category": "FrontDoorAccessLog", "enabled": true},
            {"category": "FrontDoorWebApplicationFirewallLog", "enabled": true}
        ]' \
        --metrics '[
            {"category": "AllMetrics", "enabled": true}
        ]'
fi

# Create a dummy origin group
if az afd origin-group show \
    --resource-group ${SHAREDRG} \
    --profile-name ${FRONTDOOR} \
    --origin-group-name dummy-blackhole \
    >/dev/null 2>&1
then
    echo "AFD origin group dummy-blackhole already exists"
else
    echo "Creating AFD origin group dummy-blackhole"
    az afd origin-group create \
        --resource-group ${SHAREDRG} \
        --profile-name ${FRONTDOOR} \
        --origin-group-name dummy-blackhole \
        --sample-size 4 \
        --successful-samples-required 3 \
        --additional-latency-in-milliseconds 0
fi

# Create a dummy origin that goes nowhere
if az afd origin show \
    --resource-group ${SHAREDRG} \
    --profile-name ${FRONTDOOR} \
    --origin-group-name dummy-blackhole \
    --origin-name null-origin \
    >/dev/null 2>&1
then
    echo "AFD origin null-origin already exists"
else
    echo "Creating AFD origin null-origin"
    az afd origin create \
      --resource-group ${SHAREDRG} \
      --profile-name ${FRONTDOOR} \
      --origin-group-name dummy-blackhole \
      --origin-name null-origin \
      --host-name "nowhere.invalid" \
      --http-port 80 \
      --https-port 443 \
      --enabled-state Enabled
fi

echo "SUCCESS"