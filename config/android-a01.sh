# Parameters in use
export PREFIX=a01           # As described above
export RG=rg-${PREFIX}      # Do not change
export REGION=northeurope   # Region - normally should not change

# Globally unique names, used in both bicep and in scripts
# A good way to generate this is "date | md5sum | head -c 20 && echo"
export UNIQUESTRING=c8c8f79c0b44fc22686b  # Ensure globally unique
export STORAGENAME=${UNIQUESTRING}
export TRIGGERAPPNAME=trigger-${UNIQUESTRING}
export METRICAPPNAME=vmcount-${UNIQUESTRING}

# Names of export and tiles storage buckets
export EXTRACTS_BUCKET=extracts
export PMTILES_BUCKET=pmtiles

# Area to use - should normally be "monaco" or "planet"
export AREA=planet

# This subscription stuff is purely to make sure we are using the right Azure subscription.
export SUBSCRIPTION=4bf1580a-f73d-4821-8cdc-605925ba78e9

az account set --subscription ${SUBSCRIPTION}
if [ $? -ne 0 ]; then
  echo "Failed to set Azure subscription."
  exit 1
fi
