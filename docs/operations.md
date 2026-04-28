# Operations processes

This document covers how to monitor and operate an existing deployment. It is intended for operators on call for the running service, not for the deployment process itself (which is described in the per-component deployment documents).

It is organised as follows.

- [Dashboards](#dashboards) — the per-component portal dashboards built by each deployment, and what they show.
- [Alerts](#alerts) — the alerts that fire when something is wrong, and the first action to take for each.
- [Detailed log monitoring](#detailed-log-monitoring) — the saved log queries used to investigate issues, grouped by component.

## Dashboards

### iOS dashboard

The iOS deployment process creates a dashboard, named after the resource group as `iosNN`. You can view this in the portal. It displays graphs of the following.

- Front Door requests that are at least plausibly valid - i.e. are requesting tiles from one of the valid domains.

- Tile server CPU and memory usage.

- Count of tile server instances and of trigger instances running.

- Requests handled by Front Door (whether reaching this deployment instance or another one). "Total" is the number reaching Front Door, while "Origin" is the number forwarded on to the back end instance. *This includes both iOS and photon server requests.*

- Front Door latency averages.

- Front Door error counts. These are of two categories - *Invalid requests* which are caused by script kiddies and crawlers, and are expected to fail, and *Valid requests* which are not expected to fail.

- Database CPU and memory usage.

- Database storage usage.

- Count of VM instances. There are three counters covering the following.

    - Capacity (how many VMs the VMSS is configured to run - zero normally, one when an ingestion is occurring).

    - Total instances (how many VMs the VMSS actually has). This may differ from capacity if a spot instance has failed, or if the VMSS is in the middle of scaling.

    - Healthy instances (how many VMs the VMSS actually has that are running normally). This may differ from total instances only if a VM has failed, or is in the process of starting up.

    Generally, all three values should be zero, except when an ingestion occurs when they should all increase to one then return to zero after a few (typically ten) hours.

- Tile server requests reaching the actual tile server itself. (This includes metrics for health checks.)

Most of this data can be viewed in the detailed monitoring queries below, with more information.

### Android dashboard

The android deployment process creates a dashboard, named after the resource group as `androidNN`. You can view this in the portal. It displays graphs of the following.

- Ingress and egress rates for the data transfer storage account.

- Storage capacity used for the data transfer storage account.

- Count of VM instances, as for iOS above.

### Photon dashboard

The photon deployment process creates a dashboard, named after the resource group as `photonNN`. You can view this in the portal. It displays graphs of the following.

- Requests handled by Front Door (whether reaching this deployment instance or another one). "Total" is the number reaching Front Door, while "Origin" is the number forwarded on to the back end instance. *This includes both iOS and photon server requests.*

- Count of requests for real photon data that were handled on the main domains, how many hit the cache, and how many were errors.

- Count of error requests, including both requests for photon data and invalid requests.

- Total bytes transmitted by the photon load balancer (to Front Door for either health requests or real traffic).

- VMSS memory and CPU usage.

- Legacy URL traffic (to the old URL, from legacy devices).

- Count of VM instances, as for iOS above. Note however that normally one VM will be active and healthy in normal operation, rather than zero.

## Alerts

A range of alerts are configured, and will be seen in email reports sent to the configured users.

- Severity 4: a VM (iOS or Android) successfully ran to completion.

    - First action: none — informational only.

- Severity 1: a VM (iOS or Android) reported an error.

    - First action: open the relevant dashboard ([iOS](#ios-dashboard) or [Android](#android-dashboard)) to confirm the VMSS state, then run the high-level ingestion query (`iOS ingestion - high level` or `Android VM processing - high level`) to find the failing step. The detailed-logs query for the same component covers the run output.

- Severity 1: a VM (iOS or Android) took so long to complete that it must have failed (and presumably the termination script did not work to report the error).

    - First action: as above. Additionally, check the VMSS in the portal — if a VM is still running, terminate it manually. The next scheduled run will then start cleanly. The cause of the hang is normally visible in the detailed-logs query, even though the VM did not write a final error.

- Severity 2: errors are reported in Azure Front Door for Soundscape iOS requests.

    - First action: run `iOS Front Door Errors` (note that this query lives in the shared workspace, see below). If errors are concentrated on a single endpoint or path, check the corresponding tilesrv logs (`iOS tilesrv access logs`) for the same time window.

For photon:

- Severity 4: a reimage of the photon VMSS has started.

    - First action: none — informational only.

- Severity 1: no healthy VMs exist in the photon VMSS.

    - First action: open the [photon dashboard](#photon-dashboard) and check VM instance counts. Run `Photon VM logs - high level` and `Photon Container logs` to find why the VM failed to come up. If the VM is still attempting startup, allow up to 30 minutes — the photon database build is slow.

- Severity 1: more than one VM exists in the photon VMSS, implying that the VMSS reimage failed to complete in some way.

    - First action: run `Photon function app logs` to find why the reimage health-check loop did not converge. The function app reimage logic lives in `src/trigger/reimage.py` and times out if neither VM reaches a healthy state.

- Severity 2: errors are reported in Azure Front Door for photon requests.

    - First action: run `Photon Front Door Errors` (in the shared workspace, see below) and `Photon Container logs` for the same window.

## Detailed log monitoring

A range of detailed diagnostics queries have been created which should allow easier checking of logs, with standard logs queries.

*Note on Front Door logs:* unlike the per-component logs (which live in the deployment RG's Log Analytics workspace), all Front Door logs — for both iOS and photon — live in the workspace in the shared resource group `soundscape-shared`. This affects all queries below whose names start with `iOS Front Door` or `Photon Front Door`. Android does not currently have Front Door log queries because Android tile and extracts traffic is served directly by Cloudflare, not Front Door.

### Using the queries

All of the requests listed here are stored in a deployed query pack. To view them, do the following.

- In the [Azure portal](https://portal.azure.com), find the resource group.

- Select the Log Analytics Workspace, and click on it.

- On the left hand panel click on `Logs`

- Click on the `Queries` button to the left of the window.

- Type in `ios` or `android` in the search window. This will show all the relevant saved queries.

- Click on the one you want to view, as listed below.

*If the queries do not show up, this is because you have never selected the query pack. Instead of searching, click the three dots by the search window, click `Select Query Packs` and find the iOS or Android pack.*

### iOS logs

#### Ingestion VMs

The ingestion of data is done by a VM that is started once a week then shuts down again when complete, and generates logs. *These logs do not appear until some time after the VM is created - typically at least ten minutes.* The main logs for this VM are in the following queries.

- `iOS ingestion - high level`: high level logs of when the ingestion started and finished.

- `iOS ingestion - detailed logs`: detailed logs of the ingestion process. These are very large, with logs at roughly one per minute intervals.

When running, the ingestion VM runs a performance test to validate that all is well (the same one run during the cutover process). Results from this test can be viewed with the following queries.

- `iOS summary of performance logs`: a summary of outputs so far, emitted every few minutes.

- `iOS detailed list of perf results`: a detailed view of every request, time taken, and result.

- `iOS detailed list of perf errors`: a detailed view of every request that failed.

You can see how many VMs were running and when using the following.

- `iOS VM instance count`: a view of VM capacity and instance counts over time.

#### Tile server

The tile server has a range of logs.

- `iOS tilesrv access logs`: all access logs for the tile server, one per request. Does not include requests satisfied by front door cache (which do not reach the tilesrv) but does include liveness checks.

- `iOS tilesrv access logs summary`: hourly summary of access logs. *This is very useful for getting an idea of whether all is well.*

#### Function app

The function apps (that trigger VM creation for ingestion) generate logs when they run. They are not usually very important, but if you need them, they are shown here.

- `iOS function app logs`: all low level logs from Azure Functions.

#### Front door logs

- `iOS Front Door metrics`: this shows an hourly summary of incoming traffic to Front Door. *It includes both iOS and photon search requests, unlike the other Front Door requests based on access logs.*

- `iOS Front Door Access Log summary`: this shows a daily summary of incoming traffic, with counts based on parsed into country, URL, and unique users.

- `iOS Front Door Access Logs`: this shows all access logs from Front Door, with some useful information.

- `iOS Front Door Errors`: this is a subset of the access log view that only shows errors.

- `iOS Front Door response times`: this shows a daily summary of response times for successful requests - average, median, and P95 and P99.

#### PostgreSQL logs

These logs show errors from the SQL database.

- `iOS SQL Logs`: all SQL logs from PostgreSQL.

### Android logs

#### Ingestion VMs

The ingestion of data is done by a VM that is started once a week then shuts down again when complete, and generates logs. *These logs do not appear until some time after the VM is created - typically at least ten minutes.* The main logs for this VM are in the following queries.

- `Android VM processing - high level`: high level logs of when the ingestion started and finished.

- `Android VM processing - detailed logs`: detailed logs of the ingestion process. These are very large, with logs at roughly one per minute intervals.

You can see how many VMs were running and when using the following.

- `Android VM instance count`: a view of VM capacity and instance counts over time.

#### Function app

The function app (that triggers VM creation for ingestion) generate logs when they run. They are not usually very important, but if you need them, they are shown here.

- `Android function app logs`: all low level logs from Azure Functions.

#### Cloudflare metrics

The cfmetrics function app runs hourly and writes worker and R2 bucket metrics to Application Insights. All entries use the `CLOUDFLARE:` prefix. The following query is available.

- `Android Cloudflare worker and R2 metrics`: hourly summary of Cloudflare metrics, one row per hour/script/metric combination. Metrics include:

    - `worker requests`: total worker invocations in the hour
    - `worker requests success`: invocations that completed successfully
    - `worker requests scriptThrewException`: invocations where the worker threw an uncaught exception
    - `worker requests clientDisconnected`: invocations where the client disconnected before the response was sent
    - `worker responseBodySize`: total response body bytes sent to clients
    - `worker wallTimeMs`: total wall-clock time in milliseconds across all invocations
    - `worker cpuTimeMs`: total CPU time in milliseconds across all invocations
    - `r2 objectCount`: current number of objects in the R2 bucket
    - `r2 payloadSizeBytes`: current total payload size of the R2 bucket in bytes

    All metrics are reported for both the pmtiles and extracts scripts.

##### Limitations

HTTP response status codes (e.g. 503 "data not available yet" from the extracts worker) are not available via the Cloudflare analytics API at the account level. Distinguishing 503s from 200s requires instrumenting the workers with the Workers Analytics Engine — this is deferred to a future phase.

### Photon logs

Photon log queries are as follows.

#### Photon VM

- `Photon VM logs - high level`: high level logs from the photon server, showing initialisation

- `Photon Container logs`: logs from the containers running on the photon server, showing what both the photon instance itself and the health container are doing.

- `Photon VM instance count`: a view of VM capacity and instance counts over time.

#### Function app

- `Photon function app logs`: all low level logs from Azure Functions; more interesting than for the other cases as the function app logic is more complex.

#### Front door logs

- `Photon Front Door metrics`: this shows an hourly summary of incoming traffic to Front Door. *It includes both iOS and photon search requests, unlike the other Front Door requests based on access logs.*

- `Photon Front Door Access Log summary`: this shows a daily summary of incoming traffic, with counts based on parsed into country, URL, and unique users.

- `Photon Front Door Access Logs`: this shows all access logs from Front Door, with some useful information.

- `Photon Front Door Errors`: this is a subset of the access log view that only shows errors.

- `Photon Front Door response times`: this shows a daily summary of response times for successful requests - average, median, and P95 and P99.

## Common issues

This section collects known failure modes and the first-look response for each. It is not exhaustive — the alert first-actions above and the per-component log queries are normally sufficient — but it captures recurring issues that are not obvious from the dashboards alone.

- **`PrincipalNotFound` during `iosbase.sh`.** Intermittent. The base deploy script assigns a managed identity a role before Entra has propagated the identity's existence. The script will then fail with `PrincipalNotFound`. Mitigation: simply re-run `iosbase.sh`. The script is safe to re-run.

- **iOS ingestion VM still running after 12 hours.** The full-globe ingestion takes 8–10 hours; significantly longer means the VM is stuck. Run `iOS ingestion - detailed logs` and look for the last log line — `imposm3` typically logs once per minute. If the VM is genuinely hung (no log output for >30 minutes), terminate it manually in the portal; the next scheduled timer run will start cleanly.

- **Android ingestion run failed but no production worker change occurred.** This is the expected behaviour: the upload tooling validates the new data through the `*-test` workers before promoting it to the production workers. A failure during validation leaves production untouched. Check `Android VM processing - high level` to find the failing step, fix the underlying issue, and re-trigger the timer.

- **Photon VMSS has two VMs and never returns to one.** The reimage logic in `src/trigger/reimage.py` waits for both VMs to be healthy before deleting the older one. If the new VM never reaches a healthy state, the VMSS stays at capacity 2 indefinitely. Run `Photon function app logs` and `Photon VM logs - high level` to diagnose; a manual delete of the stuck instance may be required.

- **Front Door 5xx spike with no corresponding origin spike.** Front Door reports errors that the origin never sees (TLS handshake failures, Front Door internal errors). Run `iOS Front Door Errors` (or `Photon Front Door Errors`) and check the error category column — `OriginConnectionAborted` and similar indicate origin-side issues; other categories may indicate Front Door or client-side issues.
