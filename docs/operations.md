# Operations processes

## Dashboard

The deployment process creates a dashboard, named after the resource group as `rg-pNN`. You can view this in the portal. It displays graphs of the following.

- Tile server requests reaching the deployment, with counts of success and errors. (Some errors are expected, notably 404s for random requests against the domain.)

- Tile server CPU and memory usage.

- Count of tile server instances and of trigger instances running.

- Requests handled by Front Door (whether reaching this deployment or another one).

- Front Door latency

- Count of VMs running. This should be zero unless an ingestion is occurring.

- Database CPU and memory usage.

- Database storage usage.

## Detailed monitoring

All of the requests below are stored in a deployed query pack. To view them, do the following.

- In the [Azure portal](https://portal.azure.com), find the resource group.

- Select the Log Analytics Workspace, and click on it.

- On the left hand panel click on `Logs`

- Click on the `Queries` button to the left of the window.

- Type in `Soundscape` in the search window. This will show all the relevant saved queries.

- Click on the one you want to view, as listed below.

### Ingestion VMs

The ingestion of data is done by a VM that is started once a week then shuts down again when complete, and generates logs. *These logs do not appear until some time after the VM is created - typically at least ten minutes.* The main logs for this VM are in the following queries.

- `Soundscape ingestion - high level`: high level logs of when the ingestion started and finished.

- `Soundscape ingestion - detailed logs`: detailed logs of the ingestion process. These are very large, with logs at roughly one per minute intervals.

When running, the ingestion VM runs a performance test to validate that all is well (the same one run during the cutover process). Results from this test can be viewed with the following queries.

- `Soundscape summary of performance logs`: a summary of outputs so far, emitted every few minutes.

- `Soundscape detailed list of perf results`: a detailed view of every request, time taken, and result.

- `Soundscape detailed list of perf errors`: a detailed view of every request that failed.

### Tile server

The tile server has a range of logs.

- `Soundscape tilesrv access logs`: all access logs for the tile server, one per request. Does not include

- `Soundscape tilesrv access logs summary`: hourly summary of access logs. *This is very useful for getting an idea of whether all is well.*

### Function app

The function apps (that trigger VM creation for ingestion) generate logs when they run. They are not usually very important, but if you need them, they are shown here.

- `Soundscape function app logs`: all low level logs from Azure Functions.

### Front door logs

Unlike the other logs, the Front Door logs do not appear in the log analytics workspace in the deployment RG, but in the one in the shared resource group `rg-ssp-shared-dev-uks`. There is one such query stored.

- `Soundscape Front Door metrics`: this shows an hourly summary of incoming traffic to Front Door.

Note that full access logs are not available for Front Door; this is to save what is probably a tiny amount of money.
