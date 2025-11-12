# Parameters in use
export PREFIX=p01
export RG=photon-${PREFIX}
export REGION=westeurope
export REGISTRYNAME=acrsspdevuks
export REGISTRYRG=rg-ssp-shared-dev-uks
export VERSION=v1.0

# Globally unique string, used in both bicep and in scripts
# A good way to generate this is "date | md5sum | head -c 20 && echo"
export UNIQUESTRING=029edfef73100f3c0334

# Area to use - should normally be "monaco" or "planet"
export AREA=planet

# Subscription to use.
export SUBSCRIPTION=4bf1580a-f73d-4821-8cdc-605925ba78e9
