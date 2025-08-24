# Operations processes

## Logging

Logs can be found by going to the Log Analytics Workspace in the portal, and entering various selection strings.

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

### Function app

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

*To be provided*