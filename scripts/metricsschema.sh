#!/bin/bash
# Apply the usage-metrics schema and access control (historical-usage-superset, #35).
#
# Standalone step, run AFTER scripts/metricsdeploy.sh and by the *same* operator: the
# bicep binds both the Postgres Entra admin and Key Vault Secrets Officer to that
# user's object id, so a different operator would have neither DB admin rights nor the
# Key Vault grant this script needs. Idempotent — safe to re-run.
#
# Requires: az CLI (logged in as that operator), the psql client, jq, and curl.
#
# psql connects from this workstation, whose public IP is not in the server firewall
# (the bicep's AllowAllAzureIPs rule only covers Azure-internal callers like the reader
# functions). The script therefore opens a temporary firewall rule for this machine's
# public IP and removes it on exit, so no standing hole is left for a workstation.
#
# Creates (all idempotent):
#   - table usage_metrics + its NULLS NOT DISTINCT unique index
#   - the shared reader's Entra-mapped writer role (metrics-uami), keyed to its UAMI
#     object id, with INSERT/UPDATE/SELECT on usage_metrics
#   - a read-only Superset login role (superset_ro) with SELECT, its password generated
#     once into Key Vault (reused on re-run; --regenerate-superset-password forces a new
#     one)
#   - the Superset source-IP firewall rule, if METRICS_SUPERSET_IP is set
#
# Options:
#   --regenerate-superset-password   mint a fresh Superset password (default: reuse)
#   --add-writer <uami-name> <uami-rg>
#       Additionally grant a *per-instance* reader UAMI (e.g. the Android
#       <prefix>-metrics-uami) write access to usage_metrics — same CREATE ROLE +
#       SECURITY LABEL + GRANT as the shared reader, keyed to that UAMI's object id. Run
#       from the Android deploy after its UAMI exists (the UAMI is per-instance, so its
#       role must be (re)created on each cutover). The schema apply above still runs and
#       is idempotent, so this is just "make the writer also exist".
set -euo pipefail

# Run from the parent of the scripts directory.
cd "$(dirname "$0")/.."

# Configuration: subscription, RG, Superset IP.
. config/shared-cfg.sh

REGENERATE_SUPERSET_PW=false
ADD_WRITER_UAMI=""
ADD_WRITER_RG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --regenerate-superset-password) REGENERATE_SUPERSET_PW=true; shift ;;
    --add-writer)
      ADD_WRITER_UAMI="${2:?--add-writer needs <uami-name> <uami-rg>}"
      ADD_WRITER_RG="${3:?--add-writer needs <uami-name> <uami-rg>}"
      shift 3 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

SUPERSET_ROLE=superset_ro
SUPERSET_SECRET=superset-ro-password
METRICS_UAMI=metrics-uami

echo "Setting Azure subscription to ${SUBSCRIPTION}"
az account set --subscription ${SUBSCRIPTION}

# Discover the deployed resources from the metricsdb deployment outputs (their names
# are region-seeded in the bicep, so they cannot be reconstructed here).
echo "Reading metricsdb deployment outputs"
OUTPUTS=$(az deployment group show -g ${METRICS_RG} -n metricsdb --query properties.outputs -o json)
PG_FQDN=$(echo "${OUTPUTS}" | jq -r '.pgServerFqdn.value')
PG_SERVER=$(echo "${OUTPUTS}" | jq -r '.pgServerName.value')
PG_DATABASE=$(echo "${OUTPUTS}" | jq -r '.pgDatabaseName.value')
KV_NAME=$(echo "${OUTPUTS}" | jq -r '.keyVaultName.value')

# The shared reader UAMI's object id — the principal pgaadauth maps the role to. The
# security label (type=service, since a managed identity is a service principal) is
# what ties the Postgres role to the Entra identity.
UAMI_OID=$(az identity show -g ${METRICS_RG} -n ${METRICS_UAMI} --query principalId -o tsv)
AAD_LABEL="aadauth,oid=${UAMI_OID},type=service"

# Open a temporary firewall rule for this workstation's public IP (AllowAllAzureIPs
# does not cover it), and remove it on exit so no standing hole is left behind.
MY_IP=$(curl -fsS https://api.ipify.org)
echo "Opening temporary firewall rule for operator IP ${MY_IP}"
az postgres flexible-server firewall-rule create \
    --resource-group ${METRICS_RG} \
    --server-name ${PG_SERVER} \
    --name operator-schema-apply \
    --start-ip-address ${MY_IP} \
    --end-ip-address ${MY_IP} \
    --output none
cleanup_operator_fw() {
  echo "Removing temporary operator firewall rule"
  az postgres flexible-server firewall-rule delete \
      --resource-group ${METRICS_RG} \
      --server-name ${PG_SERVER} \
      --name operator-schema-apply \
      --yes --output none || true
}
trap cleanup_operator_fw EXIT

# Connect as the Entra admin = the signed-in operator (must be who ran the deploy).
# The Postgres access token is used as the password; the username is the operator UPN.
ADMIN_UPN=$(az ad signed-in-user show --query userPrincipalName -o tsv)
echo "Connecting to ${PG_FQDN}/${PG_DATABASE} as Entra admin ${ADMIN_UPN}"
PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)
export PGPASSWORD
PSQL=(psql "host=${PG_FQDN} port=5432 dbname=${PG_DATABASE} user=${ADMIN_UPN} sslmode=require" -v ON_ERROR_STOP=1)

# Superset read-only password: generate once into Key Vault, reuse on re-run. The
# native reader path never uses this (Entra tokens) — only Superset does.
SUPERSET_PW=$(az keyvault secret show --vault-name ${KV_NAME} --name ${SUPERSET_SECRET} --query value -o tsv 2>/dev/null || true)
GENERATED_PW=false
if [ -z "${SUPERSET_PW}" ] || [ "${REGENERATE_SUPERSET_PW}" = true ]; then
  echo "Generating a new Superset read-only password into Key Vault"
  SUPERSET_PW=$(openssl rand -base64 24)
  az keyvault secret set --vault-name ${KV_NAME} --name ${SUPERSET_SECRET} --value "${SUPERSET_PW}" --output none
  GENERATED_PW=true
else
  echo "Reusing the existing Superset read-only password from Key Vault"
fi

# Schema + roles. The heredoc is single-quoted so bash leaves it alone; psql does the
# :var substitution (:'x' = quoted literal, :"x" = quoted identifier). The two
# conditional statements use `SELECT … WHERE NOT EXISTS` so the create runs only when
# the role is absent — the create expression is not evaluated when the guard matches.
echo "Applying schema and roles"
"${PSQL[@]}" \
  -v aad_label="${AAD_LABEL}" \
  -v uami_role="${METRICS_UAMI}" \
  -v superset_role="${SUPERSET_ROLE}" \
  -v superset_pw="${SUPERSET_PW}" \
  -v dbname="${PG_DATABASE}" <<'EOSQL'
-- Narrow/long metrics table + natural-key unique index. NULLS NOT DISTINCT makes two
-- NULL countries collide, so the Cloudflare (NULL-country) rows upsert to one row/hour.
CREATE TABLE IF NOT EXISTS usage_metrics (
    metric_ts    timestamptz  NOT NULL,  -- start of the hour, UTC
    metric_name  varchar(64)  NOT NULL,  -- e.g. 'ios_requests', 'ios_sessions'
    source_rg    varchar(64)  NOT NULL,  -- originating RG; sum/zoom across cutovers
    country      varchar(128),           -- Front Door clientCountry_s verbatim; NULL where none
    value        bigint       NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_usage_metrics
    ON usage_metrics (metric_ts, metric_name, source_rg, country) NULLS NOT DISTINCT;

-- Shared reader: Entra-mapped writer role. Rather than the pgaadauth_create_principal_with_oid
-- wrapper (whose signature varies by server version), use the primitive it wraps:
-- CREATE ROLE + a "pgaadauth" security label keyed to the UAMI object id. Both idempotent
-- (CREATE guarded by NOT EXISTS; re-applying the same label is a no-op).
SELECT format('CREATE ROLE %I WITH LOGIN', :'uami_role')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'uami_role')
\gexec

SECURITY LABEL FOR "pgaadauth" ON ROLE :"uami_role" IS :'aad_label';

GRANT CONNECT ON DATABASE :"dbname" TO :"uami_role";
GRANT USAGE ON SCHEMA public TO :"uami_role";
GRANT INSERT, UPDATE, SELECT ON usage_metrics TO :"uami_role";

-- Superset read-only login role: created with the current password if absent.
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'superset_role', :'superset_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'superset_role')
\gexec

GRANT CONNECT ON DATABASE :"dbname" TO :"superset_role";
GRANT USAGE ON SCHEMA public TO :"superset_role";
GRANT SELECT ON usage_metrics TO :"superset_role";
EOSQL

# If we minted a new password, force the role's password to match Key Vault (the
# create-if-absent above leaves an existing role's password untouched).
if [ "${GENERATED_PW}" = true ]; then
  echo "Setting the Superset role password to the new value"
  "${PSQL[@]}" -v superset_role="${SUPERSET_ROLE}" -v superset_pw="${SUPERSET_PW}" <<'EOSQL'
ALTER ROLE :"superset_role" WITH PASSWORD :'superset_pw';
EOSQL
fi

# Optional: grant a per-instance reader UAMI (e.g. the Android <prefix>-metrics-uami)
# write access, over the same admin connection. Keyed to that UAMI's object id via a
# pgaadauth SECURITY LABEL, exactly like the shared reader's role.
if [ -n "${ADD_WRITER_UAMI}" ]; then
  echo "Granting writer role '${ADD_WRITER_UAMI}' (UAMI in ${ADD_WRITER_RG})"
  WRITER_OID=$(az identity show -g "${ADD_WRITER_RG}" -n "${ADD_WRITER_UAMI}" --query principalId -o tsv)
  WRITER_LABEL="aadauth,oid=${WRITER_OID},type=service"
  "${PSQL[@]}" \
    -v writer_role="${ADD_WRITER_UAMI}" \
    -v writer_label="${WRITER_LABEL}" \
    -v dbname="${PG_DATABASE}" <<'EOSQL'
SELECT format('CREATE ROLE %I WITH LOGIN', :'writer_role')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'writer_role')
\gexec
SECURITY LABEL FOR "pgaadauth" ON ROLE :"writer_role" IS :'writer_label';
GRANT CONNECT ON DATABASE :"dbname" TO :"writer_role";
GRANT USAGE ON SCHEMA public TO :"writer_role";
GRANT INSERT, UPDATE, SELECT ON usage_metrics TO :"writer_role";
EOSQL
fi

# Superset source-IP firewall rule (control-plane). Skipped until the IP is known.
if [ -n "${METRICS_SUPERSET_IP}" ]; then
  echo "Adding Postgres firewall rule for Superset IP ${METRICS_SUPERSET_IP}"
  az postgres flexible-server firewall-rule create \
      --resource-group ${METRICS_RG} \
      --server-name ${PG_SERVER} \
      --name superset \
      --start-ip-address ${METRICS_SUPERSET_IP} \
      --end-ip-address ${METRICS_SUPERSET_IP} \
      --output none
else
  echo "METRICS_SUPERSET_IP not set — skipping the Superset firewall rule"
fi

echo "SUCCESS"
