# Script that sets up supplementary configuration for deployment scripts
# This is sourced from various other scripts.
export STORAGENAME=${UNIQUESTRING}
export TRIGGERAPPNAME=trigger-${UNIQUESTRING}
export METRICAPPNAME=vmcount-${UNIQUESTRING}
export TILESRVAPPNAME=tilesrv-${UNIQUESTRING}

# This just checks that we are using the right Azure subscription.
# If not, it sets it, and if that fails expects the sourcing script to bomb out.
echo "Setting Azure subscription to ${SUBSCRIPTION}"
az account set --subscription ${SUBSCRIPTION}

# Get the scripts directory and source everything else.
SCRIPT_DIR=$(dirname "$BASH_SOURCE")
. "${SCRIPT_DIR}/../config/shared-cfg.sh"
. "${SCRIPT_DIR}/../config/diags-cfg.sh"