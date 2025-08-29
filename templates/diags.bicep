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

