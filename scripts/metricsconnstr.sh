#!/bin/bash
# Print the SQLAlchemy connection string for the read-only Superset login to the
# usage-metrics database (historical-usage-superset, issue #35). Paste the output into
# Superset's "SQLAlchemy URI" field (or use it with any SQLAlchemy client).
#
# The output embeds the read-only password (URL-encoded), so treat it as a secret.
# It reads the host / database / Key Vault name from the metricsdb deployment outputs
# and the password from Key Vault.
#
# Requires: az CLI (logged in) and jq.
set -euo pipefail

# Run from the parent of the scripts directory.
cd "$(dirname "$0")/.."

# Configuration: subscription, RG.
. config/shared-cfg.sh

az account set --subscription ${SUBSCRIPTION} >/dev/null

HOST=$(az deployment group show -g ${METRICS_RG} -n metricsdb --query properties.outputs.pgServerFqdn.value -o tsv)
DB=$(az deployment group show   -g ${METRICS_RG} -n metricsdb --query properties.outputs.pgDatabaseName.value -o tsv)
KV=$(az deployment group show   -g ${METRICS_RG} -n metricsdb --query properties.outputs.keyVaultName.value -o tsv)
PW=$(az keyvault secret show --vault-name ${KV} --name superset-ro-password --query value -o tsv)

# URL-encode the password so any base64 special characters (+ / =) are URI-safe.
PW_ENC=$(jq -rn --arg x "${PW}" '$x|@uri')

echo "postgresql://superset_ro:${PW_ENC}@${HOST}:5432/${DB}?sslmode=require"
