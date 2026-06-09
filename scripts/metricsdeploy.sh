#!/bin/bash
# Deploy the usage-metrics stack (historical-usage-superset, issue #35) into its
# own RG (soundscape-metrics). Run as a step in the infra deploy, after the shared
# RG exists — it reads the shared Log Analytics workspace for Front Door metrics.
set -euo pipefail

# Run from the parent of the scripts directory.
cd "$(dirname "$0")/.."

# Configuration: RG names, region, subscription, shared workspace.
. config/shared-cfg.sh

echo "Setting Azure subscription to ${SUBSCRIPTION}"
az account set --subscription ${SUBSCRIPTION}

echo "METRICS_RG: ${METRICS_RG} (${METRICS_REGION})"
az group create --location ${METRICS_REGION} --resource-group ${METRICS_RG}

# The Postgres server's Entra admin is set to the signed-in deploying user: an Entra
# admin is required so the schema step can create the readers' Entra (UAMI) roles,
# and the deploying operator is the natural choice (Owner RBAC alone cannot connect).
METRICS_ADMIN_OID=$(az ad signed-in-user show --query id -o tsv)
METRICS_ADMIN_LOGIN=$(az ad signed-in-user show --query userPrincipalName -o tsv)

# A native (password) admin is mandatory when password auth is enabled (which it must
# be, for the Superset read-only login). The password is minted inside the template
# via newGuid() (a fresh value each deploy) and mirrored into Key Vault, so it never
# lands on this machine. Rotating it per deploy is harmless: the readers authenticate
# with Entra tokens, and the Superset role has its own separate password — only
# break-glass operators read this one.
echo "Deploying usage-metrics database and shared reader function app"
az deployment group create \
    --resource-group ${METRICS_RG} \
    --name metricsdb \
    --template-file templates/metricsdb.bicep \
    --parameters sharedRG=${SHAREDRG} \
                 sharedLAW=${SHAREDLAW} \
                 pgAadAdminLogin="${METRICS_ADMIN_LOGIN}" \
                 pgAadAdminObjectId="${METRICS_ADMIN_OID}"

echo "SUCCESS"
