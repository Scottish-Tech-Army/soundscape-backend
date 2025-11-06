# Parameters in use
export PREFIX=a02
export RG=rg-${PREFIX}
export REGION=westeurope

# Globally unique names, used in both bicep and in scripts
# A good way to generate this is "date | md5sum | head -c 20 && echo"
export UNIQUESTRING=d41d8cd98f00b204e980 # Ensure globally unique

# Names of export and tiles storage buckets
export EXTRACTS_BUCKET=extracts
export PMTILES_BUCKET=pmtiles

# Area to use - should normally be "monaco" or "planet"
export AREA=planet

# Subscription to use.
export SUBSCRIPTION=4bf1580a-f73d-4821-8cdc-605925ba78e9

