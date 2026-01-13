# Parameters in use
export PREFIX=i05
export RG=ios05
export REGION=northeurope
export VERSION=v1.1
export AREA=planet

# Do not use SPOT VMS
export USE_SPOT=false

# Globally unique string, used in both bicep and in scripts
# A good way to generate this is "date | md5sum | head -c 20 && echo"
export UNIQUESTRING=af287e97cc641f0914ed

# This subscription stuff is purely to make sure we are using the right Azure subscription.
export SUBSCRIPTION=9ff2d6b4-099b-4370-9629-6f490b4ac356
