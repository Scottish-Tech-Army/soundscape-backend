@description('Name for the query pack')
param queryPackName string = 'photon-queries'

// Root query pack
resource queryPack 'Microsoft.OperationalInsights/queryPacks@2025-02-01' = {
  name: queryPackName
  location: resourceGroup().location
  properties: {}
}

module photonHighLevel './query.bicep' = {
  name: 'photonHighLevel'
  params: {
    queryPackName: queryPackName
    displayName: 'Photon VM logs - high level'
    queryDescription: 'High-level photon VM logs'
    query: '''
    photonLogs_CL
    | where FilePath contains "svc"
    | order by TimeGenerated desc
    '''
  }
}

module photonContainerLogs './query.bicep' = {
  name: 'photonContainerLogs'
  params: {
    queryPackName: queryPackName
    displayName: 'Photon Container logs'
    queryDescription: 'Low level logs of photon VM'
    query: '''
    photonLogs_CL
    | where FilePath !contains "svc"
    | extend parsed = parse_json(RawData)
    | extend
      Message = tostring(parsed.log),
      Stream  = tostring(parsed.stream),
      EventTime = todatetime(parsed["time"])
    | project-reorder EventTime, Stream, Message, Computer
    | order by EventTime, TimeGenerated desc
    '''
  }
}

module vmCount './query.bicep' = {
  name: 'vmCount'
  params: {
    queryPackName: queryPackName
    displayName: 'Photon VM instance count'
    queryDescription: 'Capacity and VM instance counts for the photon VMSS'
    query: '''
    AppTraces
    | where Message contains "METRIC:"
    | extend MetricName = extract(@"METRIC: ([\w ]+):", 1, Message)
    | extend Value = toint(extract(@"METRIC: [\w ]+: (\d+)", 1, Message))
    | extend Time = bin(TimeGenerated, 60m)
    | evaluate pivot(MetricName, max(Value), Time)
    '''
  }
}

module functionApp './query.bicep' = {
  name: 'photonFunctionApp'
  params: {
    queryPackName: queryPackName
    displayName: 'Photon function app logs'
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
    displayName: 'Photon Front Door metrics (including all traffic, not just photon)'
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
    displayName: 'Photon Front Door Access Log summary'
    queryDescription: 'Front door access logs summary for photon search'
    query: '''
    AzureDiagnostics
    | where Category == "FrontDoorAccessLog"
    | where requestUri_s startswith "https://photon." or requestUri_s startswith "https://photontest."
    | where requestUri_s contains "/photon/"
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
    displayName: 'Photon Front Door Access Logs'
    queryDescription: 'All Front Door access logs for photon search'
    query: '''
    AzureDiagnostics
    | where Category == "FrontDoorAccessLog"
    | where requestUri_s startswith "https://photon." or requestUri_s startswith "https://photontest."
    | project TimeGenerated, requestUri_s, userAgent_s, httpMethod_s, httpStatusCode_s, httpStatusDetails_s, clientCountry_s, errorInfo_s, timeTaken_s
    | order by TimeGenerated desc
    '''
  }
}

module frontDoorAccessLogErrors './query.bicep' = {
  name: 'frontDoorAccessLogErrors'
  params: {
    queryPackName: queryPackName
    displayName: 'Photon Front Door Errors'
    queryDescription: 'Front door errors from access logs for photon search'
    query: '''
    AzureDiagnostics
    | where Category == "FrontDoorAccessLog"
    | where requestUri_s startswith "https://photon." or requestUri_s startswith "https://photontest."
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
    displayName: 'Photon Front Door response times'
    queryDescription: 'Front door response time summary for photon search'
    query: '''
    AzureDiagnostics
    | where Category == "FrontDoorAccessLog"
    | where requestUri_s startswith "https://photon." or requestUri_s startswith "https://photontest."
    | where requestUri_s contains "/photon/"
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


