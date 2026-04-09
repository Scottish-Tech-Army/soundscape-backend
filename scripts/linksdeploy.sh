#!/bin/bash
# Set up links site storage and upload assetlinks.json
set -euo pipefail
echo "LINKSRG: ${LINKSRG}"

# This script must run from the parent directory of the scripts directory
cd "$(dirname "$0")/.."

# Check we are logged into the correct subscription
az account set --subscription ${SUBSCRIPTION}

# Create the resource group
az group create --location ${LINKSREGION} --resource-group ${LINKSRG}

# Create the storage account
if az storage account show \
    --name ${LINKSSTORAGENAME} \
    --resource-group ${LINKSRG} \
    >/dev/null 2>&1
then
    echo "Storage account ${LINKSSTORAGENAME} already exists"
else
    echo "Creating storage account ${LINKSSTORAGENAME}"
    az storage account create \
        --name ${LINKSSTORAGENAME} \
        --resource-group ${LINKSRG} \
        --location ${LINKSREGION} \
        --sku Standard_LRS \
        --kind StorageV2 \
        --allow-shared-key-access false
fi

# Grant the current user Storage Blob Data Contributor on the storage account.
# Required because shared key access is disabled; Azure AD is the only auth method.
# RBAC propagation can take a minute, so we sleep if the role was just assigned.
STORAGE_ID=$(az storage account show \
    --name ${LINKSSTORAGENAME} \
    --resource-group ${LINKSRG} \
    --query id -o tsv)
CURRENT_USER=$(az ad signed-in-user show --query id -o tsv)

if az role assignment list \
    --assignee ${CURRENT_USER} \
    --role "Storage Blob Data Contributor" \
    --scope ${STORAGE_ID} \
    --query "[0].id" -o tsv 2>/dev/null | grep -q .
then
    echo "Storage Blob Data Contributor role already assigned"
else
    echo "Assigning Storage Blob Data Contributor role to current user"
    az role assignment create \
        --role "Storage Blob Data Contributor" \
        --assignee ${CURRENT_USER} \
        --scope ${STORAGE_ID}
    echo "Waiting 60s for RBAC propagation (re-run if sync fails with 403)..."
    sleep 60
fi

# Enable static website hosting (idempotent)
echo "Enabling static website hosting on ${LINKSSTORAGENAME}"
az storage blob service-properties update \
    --account-name ${LINKSSTORAGENAME} \
    --auth-mode login \
    --static-website true

# Sync site content to the $web container; adds new files, updates changed
# files, and deletes any blobs that no longer exist in src/links/
echo "Syncing site content"
az storage blob sync \
    --account-name ${LINKSSTORAGENAME} \
    --auth-mode login \
    --container '$web' \
    --source src/links/

echo "SUCCESS"
