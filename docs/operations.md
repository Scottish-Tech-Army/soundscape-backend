# Operations processes

## Logging

Logs can be found as follows.

- In the [Azure portal](https://portal.azure.com), find the resource group.

- Select the Log Analytics Workspace, and click on it.

- On the left hand panel click on `Logs`

- Enter your search string; see below.

### Ingestion VMs

The ingestion of data is done by a VM that is started once a week then shuts down again when complete, and generates logs. *These logs do not appear until some time after the VM is created - typically at least ten minutes.*


- The high level operations of the VM that does the ingestion, showing ingestion start and completion, can be monitored as follows.

    ~~~kql
    IngestLogs_CL
    | where FilePath contains "svc.log"
    ~~~

- More detailed operations are shown here; note that this shows quite a lot of data - hundreds to thousands of lines for a full update.

    ~~~kql
    IngestLogs_CL
    ~~~

### Ingest trigger function app

Function App logs show when the timer (or manual) function triggered to start an ingestion. This includes both logs from the system running the function and from the function itself (though the functions contain only one line, typically).

~~~kql
AppTraces
| order by TimeGenerated
~~~

### Tile server app

The tile server which returns tiles (and is ultimately the entire point of this thing) has logs here.

~~~kql
ContainerAppConsoleLogs_CL
| project TimeGenerated, _timestamp_d, ContainerName_s, ContainerId_s, Log_s
| order by _timestamp_d
~~~

## Metrics

Logs can be found as follows.

- In the [Azure portal](https://portal.azure.com), find the resource group.

- Select the Log Analytics Workspace, and click on it.

- On the left hand panel click on `Metrics`

- The default scope is the LAW itself, which is not very interesting. Click on `Scope` to change it to the right resource.

### VM metrics

- If you click down to the VMSS or to the running VM instance, you can see (for example) CPU usage, memory free, and network usage used by ingestion.

### Ingest trigger function app

About the only interesting metric here is `On Demand Function Execution Count`, which counts numbers of executions, and shows when the job triggered.

### Tile server app

The tile server container app contains a few useful metrics.

- `CPU Usage` is obviously the CPU.

- `Replica Count` is the number of instances.

- `Network In Bytes` and `Network Out Bytes` are the network traffic.

To see request counter metrics, you need to go to the Application Insights resource in the resource group.

- Click on `Metrics` in that resource.

- Leave `scope` as the Application Insights resource.

- Within the `Application Insights standard metrics` namespace, you will find:

    - `Server requests` - the count of server requests

    - `Failed requests` - the count of error message sent

- Within the `azure.applicationinsights` namespace, you will find:

    - `tile_served_count` - the number of tiles successfully returned

    - `tile_exception_count` - the number of failures to generate a tile

### Database

The database has interesting metrics including the following.

- `CPU percent` is the percentage of CPU used.

- `Memory percent` is the percentage of memory used.

- `Disk IOPS Consumed Percentage` is disk load percentage

- `Storage used` is disk space in use.

