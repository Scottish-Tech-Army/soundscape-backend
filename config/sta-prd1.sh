# Parameters in use
export SUFFIX=tst2
export RG=rg-${SUFFIX}
export REGION=uksouth
export REGISTRYNAME=acrsspdevuks
export REGISTRYRG=rg-ssp-shared-dev-uks
export VERSION=latest

# This subscription stuff is purely to make sure we are using the right Azure subscription.
export SUBSCRIPTION=b9ba9683-feef-47c8-bcc0-08e791dc1493

az account set --subscription ${SUBSCRIPTION}
if [ $? -ne 0 ]; then
  echo "Failed to set Azure subscription."
  exit 1
fi
