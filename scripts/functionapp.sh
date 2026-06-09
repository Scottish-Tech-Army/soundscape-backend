#!/bin/bash
# Publish function-app code for a deployment. Used for iOS, Android, photon, and the
# shared metrics RG — one job, no per-app config and no app names to type.
#
# Function apps are named <shortname>-<uniquestring>, and each short name matches its
# source directory under src/ (e.g. cfmetrics-xxxx -> src/cfmetrics; the shared and
# Android usage-metrics readers are both usagemetrics-xxxx -> src/usagemetrics). This
# discovers the function apps in the given resource group and publishes src/<shortname>
# to each; any app with no matching src/ directory is skipped with a warning, so
# unrelated apps are never touched.
#
# Usage:  bash scripts/functionapp.sh ${RG}
#   The resource group is a required argument (not taken from the environment): in some
#   flows more than one of RG / SHAREDRG / METRICS_RG is set, so we make the target
#   explicit. Pass ${RG} for an iOS/Android/photon instance, or ${METRICS_RG} for the
#   shared metrics reader.
#
# Requires: az CLI (logged in) + Azure Functions Core Tools (func).
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: bash scripts/functionapp.sh <resource-group>" >&2
  echo "  e.g. bash scripts/functionapp.sh \${RG}   (or \${METRICS_RG} for the shared metrics reader)" >&2
  exit 1
fi
FUNCTION_RG="$1"

cd "$(dirname "$0")/.."

# Configuration: SUBSCRIPTION.
. config/shared-cfg.sh

echo "Setting Azure subscription to ${SUBSCRIPTION}"
az account set --subscription "${SUBSCRIPTION}"

echo "Discovering function apps in RG ${FUNCTION_RG}"
mapfile -t APPS < <(az functionapp list --resource-group "${FUNCTION_RG}" --query "[].name" -o tsv)
echo "Found ${#APPS[@]} function app(s)"

for app in "${APPS[@]}"; do
  short="${app%-*}"                          # strip the trailing -<uniquestring>
  dir="src/${short}"
  if [ ! -d "${dir}" ]; then
    echo "WARNING: no source directory '${dir}' for function app '${app}' — skipping"
    continue
  fi
  echo "Publishing ${dir} -> ${app}"
  ( cd "${dir}" && func azure functionapp publish "${app}" --python )
done

echo "SUCCESS"
