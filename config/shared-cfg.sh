# Shared RG configuration
# Region and RG
export SHAREDREGION=westeurope
export DNS_SUFFIX=soundscape.scottishtecharmy.org
export SHAREDRG=soundscape-shared
export SHAREDLAW=shared-law
export REGISTRYNAME=soundscape
export REGISTRYRG=$SHAREDRG
export REGISTRYUAMI=registry-uami
export FRONTDOOR=soundscape-fd

# Subscription
export SUBSCRIPTION=9ff2d6b4-099b-4370-9629-6f490b4ac356

# The metrics stack lives in its own RG (logically separate; clearer costs). It is
# deployed by scripts/metricsdeploy.sh as a step in the infra deploy. The store is a
# PostgreSQL Flexible Server (Burstable B1ms) — the pivot from Azure SQL, which this
# subscription refuses to provision (RegionDoesNotAllowProvisioning for Microsoft.Sql).
export METRICS_RG=soundscape-metrics
export METRICS_REGION=uksouth

# Superset source IP for the Postgres firewall rule (used to let superset access the
# DB). Leave blank to skip the rule for now.
export METRICS_SUPERSET_IP=18.169.134.59