# Operations processes

## Debugging

Console logs can be found for the various container apps by going to the Log Analytics Workspace in the portal, and entering a string such as this.

~~~kql
ContainerAppConsoleLogs_CL
| project TimeGenerated, _timestamp_d, ContainerName_s, Log_s
| order by _timestamp_d
~~~