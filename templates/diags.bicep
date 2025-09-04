@description('Name for the query pack')
param queryPackName string = 'soundscape-queries'

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
    displayName: 'Soundscape summary of performance logs'
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
    displayName: 'Soundscape detailed list of perf results'
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
    displayName: 'Soundscape detailed list of perf errors'
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
    displayName: 'Soundscape ingestion - high level'
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
    displayName: 'Soundscape ingestion - detailed logs'
    queryDescription: 'Low level logs of ingestion process'
    query: '''
    IngestLogs_CL
    | where FilePath !contains "tiletest"
    | order by TimeGenerated desc
    '''
  }
}

module tilesrvLogs './query.bicep' = {
  name: 'tilesrvLogs'
  params: {
    queryPackName: queryPackName
    displayName: 'Soundscape tilesrv logs'
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
    displayName: 'Soundscape tilesrv access logs'
    queryDescription: 'Access logs for tile server'
    query: '''
    AppRequests
    | where Name !contains "metrics_handler"
    | project TimeGenerated, Url, Success, ResultCode, DurationMs
    | order by TimeGenerated desc
    '''
  }
}

module tilesrvAccessLogSummary './query.bicep' = {
  name: 'tilesrvAccessLogSummary'
  params: {
    queryPackName: queryPackName
    displayName: 'Soundscape tilesrv access logs summary'
    queryDescription: 'Summary of access log counts for tile server'
    query: '''
    AppRequests
    | where Name !contains "metrics_handler"
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
  name: 'functionApp'
  params: {
    queryPackName: queryPackName
    displayName: 'Soundscape function app logs'
    queryDescription: 'Low level logs of function app'
    query: '''
    AppTraces
    | order by TimeGenerated
    '''
  }
}

module frontDoor './query.bicep' = {
  name: 'frontDoor'
  params: {
    queryPackName: queryPackName
    displayName: 'Soundscape Front Door metrics'
    queryDescription: 'Front door metrics'
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
