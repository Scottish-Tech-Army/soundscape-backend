# Parameters in use
export SUFFIX=tst9
export RG=rg-${SUFFIX}
export REGION=uksouth
export REGISTRYNAME=acrsspdevuks
export REGISTRYRG=rg-ssp-shared-dev-uks
export VERSION=latest

# Unique storage account name (must be globally unique)
# We need to know this here, because we use it in both bicep and elsewhere.
# A good way to generate this is "date | md5sum | head -c 20 && echo"
export STORAGE=91cfe6b9088f70d36bfb

# This subscription stuff is purely to make sure we are using the right Azure subscription.
export SUBSCRIPTION=b9ba9683-feef-47c8-bcc0-08e791dc1493

az account set --subscription ${SUBSCRIPTION}
if [ $? -ne 0 ]; then
  echo "Failed to set Azure subscription."
  exit 1
fi
