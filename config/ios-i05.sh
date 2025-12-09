# Parameters in use
export PREFIX=i05
export RG=ios05
export REGION=northeurope
export REGISTRYNAME=acrsspdevuks
export REGISTRYRG=rg-ssp-shared-dev-uks
export VERSION=v1.1

export AREA=finland

# Globally unique string, used in both bicep and in scripts
# A good way to generate this is "date | md5sum | head -c 20 && echo"
export UNIQUESTRING=185a696469c6b046ee9f

# This subscription stuff is purely to make sure we are using the right Azure subscription.
export SUBSCRIPTION=b9ba9683-feef-47c8-bcc0-08e791dc1493

az account set --subscription ${SUBSCRIPTION}
if [ $? -ne 0 ]; then
  echo "Failed to set Azure subscription."
  exit 1
fi
