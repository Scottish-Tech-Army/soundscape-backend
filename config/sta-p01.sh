# Parameters in use
export PREFIX=p01
export RG=rg-${PREFIX}
export REGION=uksouth
export REGISTRYNAME=acrsspdevuks
export REGISTRYRG=rg-ssp-shared-dev-uks
export VERSION=v1.0

# Globally unique function app name, used in both bicep and in scripts
# A good way to generate this is "date | md5sum | head -c 20 && echo"
export TRIGGERAPPNAME=1633d54ddd562f0f243b
export METRICAPPNAME=88ccd28908b25161a00b
export STORAGENAME=fe6971508913740178df

# Global shared diagnostics viewing tooling
export DIAGSRG=rg-diags

# This subscription stuff is purely to make sure we are using the right Azure subscription.
export SUBSCRIPTION=b9ba9683-feef-47c8-bcc0-08e791dc1493

az account set --subscription ${SUBSCRIPTION}
if [ $? -ne 0 ]; then
  echo "Failed to set Azure subscription."
  exit 1
fi
