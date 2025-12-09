# Parameters in use
export PREFIX=a03
export RG=android03
export REGION=westeurope

# Globally unique names, used in both bicep and in scripts
# A good way to generate this is "date | md5sum | head -c 20 && echo"
export UNIQUESTRING=c9d3db3bd222f9677aa8

# Names of export and tiles storage buckets
export EXTRACTS_BUCKET=extractsdummy
export PMTILES_BUCKET=pmtilesdummy

# Area to use - should normally be "monaco" or "planet"
export AREA=monaco

# Subscription to use.
export SUBSCRIPTION=4bf1580a-f73d-4821-8cdc-605925ba78e9

