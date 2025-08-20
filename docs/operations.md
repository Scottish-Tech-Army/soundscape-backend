# Operations processes

## Debugging

Console logs can be found for the various container apps by going to the Log Analytics Workspace in the portal, and entering a string such as this.

~~~kql
ContainerAppConsoleLogs_CL
| project TimeGenerated, _timestamp_d, ContainerName_s, Log_s
| order by _timestamp_d
~~~

Finally, for the VM that actually does all the work, you can use this.

~~~kql
IngestLogs_CL
~~~

For service logs

~~~kql
IngestLogs_CL
| where FilePath contains "svc.log"
~~~

## Adding a debug container

You can add a debug container (which is quite expensive - be warned) as follows.

~~~bash
bash scripts/debug.sh
~~~

