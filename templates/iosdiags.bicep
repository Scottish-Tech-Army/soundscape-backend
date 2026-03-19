@description('Name for the query pack')
param queryPackName string = 'ios-queries'

// Root query pack
resource queryPack 'Microsoft.OperationalInsights/queryPacks@2025-02-01' = {
  name: queryPackName
  location: resourceGroup().location
  properties: {}
}

module perfLogs './query.bicep' = {
  name: 'perfLogs'
  params: {
    queryPackName: queryPackName
    displayName: 'iOS summary of performance logs'
    queryDescription: 'Summary of performance logs from ingestion VMs'
    query: '''
    IngestLogs_CL
    | where FilePath matches regex @"tiletest.*\.log"
    | order by TimeGenerated desc
    '''
  }
}

module perfCSV './query.bicep' = {
  name: 'perfCSV'
  params: {
    queryPackName: queryPackName
    displayName: 'iOS detailed list of perf results'
    queryDescription: 'All outputs from CSV performance tooling'
    query: '''
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
    '''
  }
}

module perfCSVErrors './query.bicep' = {
  name: 'perfCSVErrors'
  params: {
    queryPackName: queryPackName
    displayName: 'iOS detailed list of perf errors'
    queryDescription: 'All outputs from CSV performance tooling showing errors'
    query: '''
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
        | where (StatusCode != 200 or Error != "") and URL contains "http"
        | order by TimeGenerated desc
    '''
  }
}

module ingHighLevel './query.bicep' = {
  name: 'ingHighLevel'
  params: {
    queryPackName: queryPackName
    displayName: 'iOS ingestion - high level'
    queryDescription: 'High-level ingestion VM start/completion'
    query: '''
    IngestLogs_CL
    | where FilePath contains "svc"
    | order by TimeGenerated desc
    '''
  }
}

module ingDetail './query.bicep' = {
  name: 'ingDetail'
  params: {
    queryPackName: queryPackName
    displayName: 'iOS ingestion - detailed logs'
    queryDescription: 'Low level logs of ingestion process'
    query: '''
    IngestLogs_CL
    | where FilePath !contains "tiletest"
    | project-reorder TimeGenerated, RawData, FilePath
    | order by TimeGenerated desc
    '''
  }
}

module tilesrvLogs './query.bicep' = {
  name: 'tilesrvLogs'
  params: {
    queryPackName: queryPackName
    displayName: 'iOS tilesrv logs'
    queryDescription: 'Low level logs of tilesrv container app'
    query: '''
    ContainerAppConsoleLogs_CL
    | project TimeGenerated, _timestamp_d, ContainerName_s, ContainerId_s, Log_s
    | order by _timestamp_d
    '''
  }
}

module tilesrvAccessLogs './query.bicep' = {
  name: 'tilesrvAccessLogs'
  params: {
    queryPackName: queryPackName
    displayName: 'iOS tilesrv access logs'
    queryDescription: 'Access logs for tile server'
    query: '''
    AppRequests
    | where Name contains "tile_handler"
    | project TimeGenerated, Url, Success, ResultCode, DurationMs
    | order by TimeGenerated desc
    '''
  }
}

module tilesrvAccessLogSummary './query.bicep' = {
  name: 'tilesrvAccessLogSummary'
  params: {
    queryPackName: queryPackName
    displayName: 'iOS tilesrv access logs summary'
    queryDescription: 'Summary of access log counts for tile server'
    query: '''
    AppRequests
    | where Name contains "tile_handler"
    | summarize
        RequestCount = count(),
        TotalDurationMs = sum(DurationMs),
        AvgDurationMs = avg(DurationMs)
      by bin(TimeGenerated, 60m), ResultCode
    | order by TimeGenerated desc, ResultCode
    '''
  }
}

module functionApp './query.bicep' = {
  name: 'iosFunctionApp'
  params: {
    queryPackName: queryPackName
    displayName: 'iOS function app logs'
    queryDescription: 'Low level logs of function app'
    query: '''
    AppTraces
    | order by TimeGenerated
    '''
  }
}

module vmCount './query.bicep' = {
  name: 'vmCount'
  params: {
    queryPackName: queryPackName
    displayName: 'iOS VM instance count'
    queryDescription: 'Capacity and VM instance counts for the ingestion scale set'
    query: '''
    AppTraces
    | where OperationName == "vmcount"
    | where Message contains "METRIC:"
    | extend MetricName = extract(@"METRIC: ([\w ]+):", 1, Message)
    | extend Value = toint(extract(@"METRIC: [\w ]+: (\d+)", 1, Message))
    | extend Time = bin(TimeGenerated, 60m)
    | evaluate pivot(MetricName, max(Value), Time)
    '''
  }
}

module frontDoor './query.bicep' = {
  name: 'frontDoor'
  params: {
    queryPackName: queryPackName
    displayName: 'iOS Front Door metrics (including all traffic, not just iOS)'
    queryDescription: 'Front door metrics for all traffic, including iOS and photon search'
    query: '''
    AzureMetrics
    | where ResourceProvider == 'MICROSOFT.CDN'
    | where MetricName in ("RequestCount", "OriginRequestCount", "ResponseSize", "TotalLatency", "OriginLatency")
    | extend MetricKey = case(
        MetricName == "RequestCount", "RequestCount",
        MetricName == "OriginRequestCount", "OriginRequestCount",
        MetricName == "ResponseSize", "ResponseSize",
        MetricName == "TotalLatency", "TotalLatency",
        MetricName == "OriginLatency", "OriginLatency",
        "Other"
    )
    | summarize
        RequestCount = sumif(Total, MetricKey == "RequestCount"),
        OriginRequestCount = sumif(Total, MetricKey == "OriginRequestCount"),
        ResponseSizeTotal = sumif(Total, MetricKey == "ResponseSize"),
        ResponseSizeCount = sumif(Count, MetricKey == "ResponseSize"),
        TotalLatencyTotal = sumif(Total, MetricKey == "TotalLatency"),
        TotalLatencyCount = sumif(Count, MetricKey == "TotalLatency"),
        MaxTotalLatency = maxif(Maximum, MetricKey == "TotalLatency"),
        OriginLatencyTotal = sumif(Total, MetricKey == "OriginLatency"),
        OriginLatencyCount = sumif(Count, MetricKey == "OriginLatency"),
        MaxOriginLatency = maxif(Maximum, MetricKey == "OriginLatency")
        by bin(TimeGenerated, 60m)
    | extend
        MeanResponseSize = iif(ResponseSizeCount > 0, ResponseSizeTotal / ResponseSizeCount, 0.0),
        MeanTotalLatency = iif(TotalLatencyCount > 0, TotalLatencyTotal / TotalLatencyCount, 0.0),
        MeanOriginLatency = iif(OriginLatencyCount > 0, OriginLatencyTotal / OriginLatencyCount, 0.0)
    | project TimeGenerated, RequestCount, OriginRequestCount,
              MeanResponseSize, MeanTotalLatency, MaxTotalLatency,
              MeanOriginLatency, MaxOriginLatency
    | order by TimeGenerated desc
    '''
  }
}

module frontDoorAccessLogSummary './query.bicep' = {
  name: 'frontDoorAccessLogSummary'
  params: {
    queryPackName: queryPackName
    displayName: 'iOS Front Door Access Log summary'
    queryDescription: 'Front door access logs'
    query: '''
    AzureDiagnostics
    | where Category == "FrontDoorAccessLog"
    | where requestUri_s startswith "https://prd2." or requestUri_s startswith "https://tst."
    | where requestUri_s contains "tiles"
    | extend User = strcat(clientIp_s, ":", clientPort_s)
    | extend Time = bin(TimeGenerated, 24h)
    | summarize
        RequestCount = count(),
        UserCount = dcount(User)
        by Time, clientCountry_s, sni_s
    | project
        Time,
        Country = clientCountry_s,
        Domain = sni_s,
        RequestCount,
        UserCount
    | order by Time desc, Country asc
    '''
  }
}

module frontDoorAccessLogs './query.bicep' = {
  name: 'frontDoorAccessLogs'
  params: {
    queryPackName: queryPackName
    displayName: 'iOS Front Door Access Logs'
    queryDescription: 'All Front Door access logs'
    query: '''
    AzureDiagnostics
    | where Category == "FrontDoorAccessLog"
    | where requestUri_s startswith "https://prd2." or requestUri_s startswith "https://tst."
    | project TimeGenerated, requestUri_s, userAgent_s, httpMethod_s, httpStatusCode_s, httpStatusDetails_s, clientCountry_s, errorInfo_s, timeTaken_s
    | order by TimeGenerated desc
    '''
  }
}

module frontDoorAccessLogErrors './query.bicep' = {
  name: 'frontDoorAccessLogErrors'
  params: {
    queryPackName: queryPackName
    displayName: 'iOS Front Door Errors'
    queryDescription: 'Front door errors from access logs'
    query: '''
    AzureDiagnostics
    | where Category == "FrontDoorAccessLog"
    | where requestUri_s startswith "https://prd2." or requestUri_s startswith "https://tst."
    | where httpStatusCode_s != 200
    | project TimeGenerated, requestUri_s, userAgent_s, httpMethod_s, httpStatusCode_s, httpStatusDetails_s, clientCountry_s, errorInfo_s, timeTaken_s
    | order by TimeGenerated desc
    '''
  }
}

module frontDoorResponseTimes './query.bicep' = {
  name: 'frontDoorResponseTimes'
  params: {
    queryPackName: queryPackName
    displayName: 'iOS Front Door response times'
    queryDescription: 'Front door response time summary for iOS traffic'
    query: '''
    AzureDiagnostics
    | where Category == "FrontDoorAccessLog"
    | where requestUri_s startswith "https://prd2." or requestUri_s startswith "https://tst."
    | where requestUri_s contains "/tiles/"
    | where httpStatusCode_s == 200
    | extend Time = bin(TimeGenerated, 24h)
    | extend ResponseTimeMs = tolong(toreal(timeTaken_s) * 1000)
    | summarize
        RequestCount = count(),
        AvgResponseTime = tolong(avg(ResponseTimeMs)),
        MedianResponseTime = tolong(percentile(ResponseTimeMs, 50)),
        P95ResponseTime = tolong(percentile(ResponseTimeMs, 95)),
        P99ResponseTime = tolong(percentile(ResponseTimeMs, 99))
        by Time, sni_s
    | project
        Time,
        Domain = sni_s,
        RequestCount,
        AvgResponseTime,
        MedianResponseTime,
        P95ResponseTime,
        P99ResponseTime
    | order by Time desc
    '''
  }
}

module sqlLogs './query.bicep' = {
  name: 'sqlLogs'
  params: {
    queryPackName: queryPackName
    displayName: 'iOS SQL logs'
    queryDescription: 'Raw logs from the SQL database'
    query: '''
    PGSQLServerLogs
    | project-away ReplicaRole, Location, Type, _ResourceId, TenantId
    | project-reorder TimeGenerated, Message
    | order by TimeGenerated desc
    '''
  }
}
