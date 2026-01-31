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

module ingDetail './query.bicep' = {
  name: 'ingDetail'
  params: {
    queryPackName: queryPackName
    displayName: 'Photon VM logs - detailed logs'
    queryDescription: 'Low level logs of photon VM'
    query: '''
    photonLogs_CL
    | project-reorder TimeGenerated, RawData, FilePath
    | order by TimeGenerated desc
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

// FIXME: xxx more front door logs
