# Parameters in use
export PREFIX=p01
export RG=photon01
export REGION=westeurope
export VERSION=v1.0

# Globally unique string, used in both bicep and in scripts
# A good way to generate this is "date | md5sum | head -c 20 && echo"
export UNIQUESTRING=029edfef73100f3c0334

# Area to use - should normally be "monaco" or "planet"
#export AREA=planet # FIXME: for testing with smaller data
export AREA=monaco

# Subscription to use.
export SUBSCRIPTION=9ff2d6b4-099b-4370-9629-6f490b4ac356

