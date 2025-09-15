# Parameters in use
export PREFIX=xac
export RG=rg-${PREFIX}
export REGION=northeurope # UK south does not support the cheaper disk types
export REGISTRYNAME=acrsspdevuks
export REGISTRYRG=rg-ssp-shared-dev-uks
export VERSION=v1.0

# Globally unique function app name, used in both bicep and in scripts
# A good way to generate this is "date | md5sum | head -c 20 && echo"
export UNIQUESTRING=8f1afdcde8e92f13dd85  # Ensure globally unique
export STORAGENAME=${UNIQUESTRING}
export TRIGGERAPPNAME=trigger-${UNIQUESTRING}
export METRICAPPNAME=vmcount-${UNIQUESTRING}

# Global shared diagnostics viewing tooling
export DIAGSREGION=uksouth
export DIAGSRG=rg-diags

# This subscription stuff is purely to make sure we are using the right Azure subscription.
export SUBSCRIPTION=b9ba9683-feef-47c8-bcc0-08e791dc1493

az account set --subscription ${SUBSCRIPTION}
if [ $? -ne 0 ]; then
  echo "Failed to set Azure subscription."
  exit 1
fi
