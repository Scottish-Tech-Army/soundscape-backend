# Operations processes

## Debugging

Console logs can be found for the various container apps by going to the Log Analytics Workspace in the portal, and entering a string such as this.

~~~kql
ContainerAppConsoleLogs_CL
| project TimeGenerated, _timestamp_d, ContainerName_s, Log_s
| order by _timestamp_d
~~~

For the ingestion container created as a container group, you can use

~~~kql
ContainerInstanceLog_CL
| project TimeGenerated, ContainerName_s, Message
| order by TimeGenerated
~~~


## Adding a debug container

You can add a debug container (which is quite expensive - be warned) as follows.

~~~bash
bash scripts/debug.sh
~~~

