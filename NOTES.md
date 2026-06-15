# Notes

Non-obvious technical findings, recorded as they are discovered. Not a substitute
for the docs in `docs/` — those remain authoritative.

## Usage-metrics database (historical-usage-superset, issue #35)

- **This (nonprofit) subscription refuses new Azure SQL servers but provisions
  PostgreSQL fine — the block is `Microsoft.Sql`-specific, not subscription-wide.**
  Creating the metrics SQL server failed in *both* West Europe and North Europe
  (`RegionDoesNotAllowProvisioning`: "Location '…' is not accepting creation of new
  Windows Azure SQL Database servers at this time"). Two big regions failing together
  pointed to a subscription-offer restriction (common on Microsoft nonprofit/
  sponsorship subscriptions), not capacity; MSFT support never lifted it. **We pivoted
  to Azure Database for PostgreSQL Flexible Server (Burstable B1ms), which deployed
  cleanly on 2026-06-13** — confirming `Microsoft.DBforPostgreSQL` is *not* under the
  `Microsoft.Sql` block. The metrics stack lives in its own RG (`soundscape-metrics`)
  in `METRICS_REGION` (`uksouth`). (Historical: a failed SQL server creation leaves an
  ARM record invisible in the portal that still blocks the name on retry —
  `az sql server delete` via CLI clears it. No longer relevant now we are off SQL.)

- **Postgres Flexible Server has no serverless auto-pause, so it bills continuously
  (~£12-13/mo).** The original Azure SQL plan leaned on serverless *auto-pause* (idle
  → near-free); Flexible Server has no equivalent — you can only manually stop it, and
  it force-restarts after 7 days, which is unworkable for a Superset-facing store.
  B1ms compute (~£9-10/mo) + the minimum 32 GiB storage (~£3/mo) is therefore the
  floor for a managed instance. Accepted as the cheapest managed option, slightly over
  the £10 target. Do not enable auto-grow / HA / geo-redundant backup / a bigger SKU —
  each breaks that target.

- **A plain Postgres UNIQUE index treats NULLs as *distinct* — opposite of SQL
  Server.** The `usage_metrics` natural key includes a nullable `country` (NULL for
  Cloudflare rows, which have no country dimension). On SQL Server a unique index
  treats NULLs as equal, giving one row/hour; on Postgres the default would let those
  NULL-country rows duplicate. The index is therefore declared
  `… (metric_ts, metric_name, source_rg, country) NULLS NOT DISTINCT` (PG15+), which
  restores the collide-on-NULL behaviour so `INSERT … ON CONFLICT` dedupes correctly
  with no NULL-aware predicate. (Design-level; to be exercised in Sub-tasks 2–3.)

- **Metrics resource names are seeded from RG id *and* region.** `metricsdb.bicep`
  uses `uniqueString(resourceGroup().id, location)`, not just the RG id. This makes
  names region-specific, so redeploying the stack into a different region produces
  fresh names — sidestepping the Key Vault (90-day) and Log Analytics (14-day)
  soft-delete name locks that otherwise block a same-name recreation when relocating.
  (`metrics-plan` and `metrics-uami` are intentionally un-suffixed: App Service plans
  and UAMIs release their names immediately on delete, so they need no rotation.)

- **Reader co-location is driven by the cutover model, not a blanket rule.** The
  iOS/Android instance RGs are rebuilt on major changes (new RG built, tested
  alongside live, then cut over), so a reader pinned to a per-instance Log Analytics
  workspace must live in that instance RG to follow the cutover. The shared RG has
  no cutover model, so the shared reader (in `soundscape-metrics`) reads `shared-law`
  cross-RG, which is fine. The underlying rule is only "one reader must not pull from
  multiple workspaces/RGs at once".

- **Postgres Entra-mapped roles tie a Postgres role to a managed identity's object id, and
  must be created by a member of `azure_pg_admin`.** A one-time role create + `pgaadauth`
  `SECURITY LABEL` (see the version note below for the exact form) + table `GRANT` maps a
  role to the UAMI's object id; the UAMI then connects using an Entra access token (scope
  `https://ossrdbms-aad.database.windows.net`) as the password and the role name as the
  user. Only a member of `azure_pg_admin` — the server's Entra admin, or the native
  password admin — can create such a role; Azure RBAC Owner alone does **not** grant DB
  data-plane access. `metricsdeploy.sh` sets the Entra admin to the signed-in deploying
  operator. Bus-factor recovery: an Owner adds themselves as Entra admin
  (`az postgres flexible-server ad-admin create`, pure control-plane), or uses the native
  `pg-admin-password` break-glass secret in Key Vault.

- **Postgres Flexible Server rejects concurrent child-resource operations.** Creating
  the database, firewall rule and Entra admin in parallel fails ("a server operation is
  already in progress"); `metricsdb.bicep` chains them with explicit `dependsOn`
  (database → firewall → AAD admin) to serialise.

- **`pgaadauth_create_principal_with_oid(...)` does not exist on this server — use the
  `SECURITY LABEL` primitive instead.** Calling the documented 5-arg wrapper
  (`role, oid, type, isAdmin, isMfa`) failed with *function … does not exist*; the
  wrapper's signature varies by server version. `metricsschema.sh` instead creates the
  Entra-mapped reader role with the underlying primitive the wrapper wraps, which is
  version-stable:
  `CREATE ROLE "metrics-uami" WITH LOGIN;`
  `SECURITY LABEL FOR "pgaadauth" ON ROLE "metrics-uami" IS 'aadauth,oid=<uami-objectId>,type=service';`
  (`type=service` because a managed identity is a service principal.) Re-applying the
  same label is a no-op, so it stays idempotent.

- **A workstation `psql` connection needs its own firewall rule — `AllowAllAzureIPs`
  does not cover it.** The bicep's `AllowAllAzureIPs` (start=end=`0.0.0.0`) is the
  "allow Azure services" rule and only admits Azure-internal callers (the reader
  functions). A `psql` run from an operator workstation **times out** (packets dropped,
  not an auth error) until that workstation's *public* IP has a firewall rule.
  `metricsschema.sh` opens a temporary rule for the detected IP (`api.ipify.org`) for
  the duration of the apply and removes it on exit (`trap … EXIT`), leaving no standing
  hole. The persistent Superset rule is separate (`METRICS_SUPERSET_IP`).

- **`az postgres flexible-server firewall-rule` uses `--server-name` + `--name`** (the
  *rule* name), not `--name` for the server / `--rule-name` for the rule as the rest of
  the `az` surface might suggest. (Cost us two iterations writing `metricsschema.sh`.)

- **Connecting to Flexible Server as the Entra admin from a script:** username = the
  operator UPN (the `principalName` set as the AAD admin), password = an `oss-rdbms`
  access token (`az account get-access-token --resource-type oss-rdbms`), `sslmode=require`.
  This is how `metricsschema.sh` runs the schema/role DDL.

- **`Log Analytics Reader` role GUID is `73c42c96-874c-492b-b04d-ab87d138a893`.**
  Used in `metricsdb.bicep` to let the reader UAMI query `shared-law`. Note
  `androidbase.bicep` uses this same GUID with a comment labelling it "Log Analytics
  Contributor" — believed to be a mislabel; verify at deploy if write behaviour ever
  matters there.

- **`scripts/functionapp.sh` is discovery-based — function-app short name must match its
  `src/` directory.** It takes the RG as a required argument, lists the function apps,
  strips the `-<uniquestring>` suffix, and publishes `src/<shortname>`. This invariant is
  what removed the old per-app blocks / lookup table, and is why the cloudflare dir was
  renamed `src/cloudflaremetrics` → `src/cfmetrics` (to match its `cfmetrics-*` app) and the
  shared metrics app `metrics-fn-*` → `usagemetrics-*` (to match `src/usagemetrics`). Adding
  a new function app needs only that its name follow the convention and a matching `src/`
  dir exist. `func ... publish` resolves the app by its globally-unique name, so the RG is
  only used for discovery. NB the `cfmetrics` *app/function/OperationName* were untouched by
  the dir rename, so the KQL filtering `OperationName == "cfmetrics"` is unaffected.

- **Backfill reach differs by source — Cloudflare goes back ~3× further than Front Door.**
  The Front Door reader is capped at ~30 days by `shared-law`'s `retentionInDays: 30`. The
  Cloudflare reader reads the Android App Insights / its Log Analytics workspace, whose
  retention is longer (~90 days by default), so a backfill with `days > 30` genuinely pulls
  older `pmtiles_*`/`offline_maps_*` data — bounded by that retention and the current Android
  instance's lifetime. Observed 2026-06-14: a 100-day backfill reached back to 2026-03-19
  (~87 days). So on the first Cloudflare backfill, pass a large `days` (e.g. 90) to grab the lot.

- **Bicep: a conditionally-deployed resource referenced by its co-conditional siblings
  triggers "may be null" warnings.** In `functions.bicep` the usage-metrics `${prefix}-metrics-uami`
  is referenced by its (same-condition) role assignments and app; gating the UAMI with
  `if (...)` made bicep warn that `metricsUami.id`/`.properties` may be null. Fix: create the
  UAMI **unconditionally** (a UAMI is free) and keep only its grants + the app gated — clean
  build, at the cost of an inert unused identity on iOS/photon. (Alternative would be a
  conditionally-deployed module.)

- **Per-instance reader UAMIs get their DB writer role via `metricsschema.sh --add-writer
  <uami-name> <uami-rg>`.** The Android `${prefix}-metrics-uami` is per-instance (recreated on
  each cutover) and lives in a different RG from the metrics DB, so bicep can't grant it. The
  flag reuses the schema script's admin connection to run the same `CREATE ROLE` + `SECURITY
  LABEL` + `GRANT` for that UAMI's object id. Run it from the Android deploy after the UAMI
  exists; re-run on each cutover.

- **The timer "next occurrences" startup trace may not surface on Flex Consumption.** The
  WebJobs timer logs `The next N occurrences of the schedule (Cron: '…') will be: …` at host
  startup, but on a scale-to-zero Flex app the host is often idle, so the trace is absent
  from App Insights `traces` until the app (re)starts. To confirm a schedule: check the app
  has the `usagemetrics_timer` function registered, restart it and watch Log stream, or just
  rely on behaviour. (Also: NCRONTAB here is read 5-field minute-first — `0 3 * * *` = 03:00
  daily — proven by `cfmetrics` running at `:10` from `10 * * * *`.)

- **Superset / SQLAlchemy connection string to the metrics DB.** `scripts/metricsconnstr.sh`
  prints `postgresql://superset_ro:<pw>@<host>:5432/metrics?sslmode=require`. Three gotchas:
  `sslmode=require` is mandatory (Flexible Server rejects non-TLS); the username is the bare
  role `superset_ro`, *not* the old Single-Server `user@server` form; and the `superset_ro`
  password (generated `openssl rand -base64`) contains `+`/`/`/`=`, which **must be
  URL-encoded** in a SQLAlchemy URI (`+`→`%2B`, etc.) — the script does this via `jq @uri`.
  If entering host/user/password as *separate* Superset fields instead, use the raw
  (un-encoded) Key Vault password.
