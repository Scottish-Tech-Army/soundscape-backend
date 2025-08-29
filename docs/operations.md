# Operations processes

**TODO: clean this up. It has some useful logging and metrics info, but does not cover testing (which is mentioned in deploy.md) and should have some level of description of Azure Front Door config and diags.**

## Logging

Logs can be found as follows.

- In the [Azure portal](https://portal.azure.com), find the resource group.

- Select the Log Analytics Workspace, and click on it.

- On the left hand panel click on `Logs`

- Select your search string.

    - You can just manually enter search strings if you like.

    - Alternatively a number of standard queries have been saved off for use. Click on the query hub, and ensure that the Soundscape Query Pack (only) has been selected, and then select your query from the query button to the left of the window; if you type in "soundscape" you will find only the Soundscape related queries.

### Ingestion VMs

The ingestion of data is done by a VM that is started once a week then shuts down again when complete, and generates logs. *These logs do not appear until some time after the VM is created - typically at least ten minutes.*

- The high level operations of the VM that does the ingestion, showing ingestion start and completion, can be monitored as follows.

    ~~~kql
    IngestLogs_CL
    | where FilePath contains "svc"
    | order by TimeGenerated desc


- If you want logs of the ingestion process, then you can do the following

    ~~~kql
    IngestLogs_CL
    | where FilePath !contains "tiletest"
    | order by TimeGenerated desc
    ~~~

- Alternatively, if you want to see how a summary of how performance runs are going, try this search.

    ~~~kql
    IngestLogs_CL
    | where FilePath matches regex @"tiletest.*\.log"
    | order by TimeGenerated desc
    ~~~

    and the raw data for every request

    ~~~kql
    IngestLogs_CL
    | where FilePath matches regex @"tiletest.*\.csv"
    | extend fields = parse_csv(RawData)
    | extend
            City       = tostring(fields[1]),
            Country    = tostring(fields[2]),
            URL        = tostring(fields[3]),
            StatusCode = toint(fields[4]),
            Time_ms    = toint(fields[5]),
            DataSize   = toint(fields[6]),
            Error      = tostring(fields[7])
    | project-away fields
    | order by TimeGenerated desc
    ~~~

    Alternatively, for all of the tests that showed error results:

    ~~~kql
    IngestLogs_CL
        | where FilePath matches regex @"tiletest.*\.csv"
        | extend fields = parse_csv(RawData)
        | extend
                City       = tostring(fields[1]),
                Country    = tostring(fields[2]),
                URL        = tostring(fields[3]),
                StatusCode = toint(fields[4]),
                Time_ms    = toint(fields[5]),
                DataSize   = toint(fields[6]),
                Error      = tostring(fields[7])
        | project-away fields
        | where StatusCode != 200 or Error != ""
        | order by TimeGenerated desc
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

