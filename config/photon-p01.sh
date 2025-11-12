# Parameters in use
export PREFIX=p01
export RG=photon-${PREFIX}
export REGION=westeurope
export VERSION=v1.0

# Registry information
export REGISTRYNAME=acrsspdevuks
export REGISTRYRG=rg-ssp-shared-dev-uks
export REGISTRYSUB=b9ba9683-feef-47c8-bcc0-08e791dc1493
export REGISTRYUAMI=mi-ssp-dev-uks-acrpull


# Globally unique string, used in both bicep and in scripts
# A good way to generate this is "date | md5sum | head -c 20 && echo"
export UNIQUESTRING=029edfef73100f3c0334

# Area to use - should normally be "monaco" or "planet"
export AREA=planet

# Subscription to use.
export SUBSCRIPTION=4bf1580a-f73d-4821-8cdc-605925ba78e9
