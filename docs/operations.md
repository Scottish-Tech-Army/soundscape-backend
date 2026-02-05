# Operations processes

## Dashboards

### iOS dashboard

The iOS deployment process creates a dashboard, named after the resource group as `iosNN`. You can view this in the portal. It displays graphs of the following.

- Tile server requests reaching the deployment, with counts of success and errors. (Some errors are expected, notably 404s for random requests against the domain.)

- Tile server CPU and memory usage.

- Count of tile server instances and of trigger instances running.

- Requests handled by Front Door (whether reaching this deployment instance or another one). "Total" is the number reaching Front Door, while "Origin" is the number forwarded on to the back end instance.

- Front Door latency averages.

- Front Door error counts. These are of two categories - *Invalid requests* which are caused by script kiddies and crawlers, and are expected to fail, and *Valid requests* which are not expected to fail.

- Database CPU and memory usage.

- Database storage usage.

- Count of VM instances. There are three counters covering the following.

    - Capacity (how many VMs the VMSS is configured to run - zero normally, one when an ingestion is occurring).

    - Total instances (how many VMs the VMSS actually has). This may differ from capacity if a spot instance has failed, or if the VMSS is in the middle of scaling.

    - Healthy instances (how many VMs the VMSS actually has that are running normally). This may differ from total instances only if a VM has failed, or is in the process of starting up.

    Generally, all three values should be zero, except when an ingestion occurs when they should all increase to one then return to zero after a few (typically ten) hours.

Most of this data can be viewed in the detailed monitoring queries below, with more information.

### Android dashboard

The android deployment process creates a dashboard, named after the resource group as `androidNN`. You can view this in the portal. It displays graphs of the following.

- Ingress and egress rates for the data transfer storage account.

- Storage capacity used for the data transfer storage account.

- Count of VM instances, as for iOS above.

### Photon dashboard

The photon deployment process creates a dashboard, named after the resource group as `photonNN`. You can view this in the portal. It displays graphs of the following.

- **FIXME: document the list of graphs when complete**

- Count of VM instances, as for iOS above. Note however that normally one VM will be active and healthy in normal operation, rather than zero.


## Alerts

A range of alerts are configured, and will be seen in email reports sent to the configured users.

- Severity 4: a VM (iOS or Android) successfully ran to completion.

- Severity 1: a VM (iOS or Android) reported an error

- Severity 1: a VM (iOS or Android) took so long to complete that it must have failed (and presumably the termination script did not work to report the error)

- Severity 2: errors are reported in Azure Front Door for Soundscape iOS requests

For photon:

- Severity 4: a reimage of the photon VMSS has started

- Severity 1: no healthy VMs exist in the photon VMSS

- Severity 1: more than one VM exists in the photon VMSS, implying that the VMSS reimage failed to complete in some way

- Severity 2: errors are reported in Azure Front Door for photon requests

## Detailed log monitoring

A range of detailed diagnostics queries have been created which should allow easier checking of logs, with standard logs queries.

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

- `iOS tilesrv access logs`: all access logs for the tile server, one per request. Does not include

- `iOS tilesrv access logs summary`: hourly summary of access logs. *This is very useful for getting an idea of whether all is well.*

#### Function app

The function apps (that trigger VM creation for ingestion) generate logs when they run. They are not usually very important, but if you need them, they are shown here.

- `iOS function app logs`: all low level logs from Azure Functions.

#### Front door logs

Unlike the other logs, the Front Door logs do not appear in the log analytics workspace in the deployment RG, but in the one in the shared resource group `soundscape-shared`.

- `iOS Front Door metrics`: this shows an hourly summary of incoming traffic to Front Door. *It includes both iOS and photon search requests, unlike the other Front Door requests based on access logs.*

- `iOS Front Door Access Log summary`: this shows a daily summary of incoming traffic, with counts based on parsed into country, URL, and unique users.

- `iOS Front Door Access Logs`: this shows all access logs from Front Door, with some useful information.

- `iOS Front Door Errors`: this is a subset of the access log view that only shows errors.

#### PostGreSQL logs

These logs show errors from the SQL database.

- `iOS SQL Logs`: all SQL logs from PostGreSQL.

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

### Photon logs

Photon log queries are as follows.

#### Photon VM

- `Photon VM logs - high level`: high level logs from the photon server, showing initialisation

- `Photon Container logs`: logs from the containers running on the photon server, showing what both the photon instance itself and the health container are doing.

- `Photon VM instance count`: a view of VM capacity and instance counts over time.

#### Function app

- `Photon function app logs`: all low level logs from Azure Functions; more interesting than for the other cases as the function app logic is more complex.

#### Front door logs

Unlike the other logs, the Front Door logs do not appear in the log analytics workspace in the deployment RG, but in the one in the shared resource group `soundscape-shared`.

- `Photon Front Door metrics`: this shows an hourly summary of incoming traffic to Front Door. *It includes both iOS and photon search requests, unlike the other Front Door requests based on access logs.*

- `Photon Front Door Access Log summary`: this shows a daily summary of incoming traffic, with counts based on parsed into country, URL, and unique users.

- `Photon Front Door Access Logs`: this shows all access logs from Front Door, with some useful information.

- `Photon Front Door Errors`: this is a subset of the access log view that only shows errors.

