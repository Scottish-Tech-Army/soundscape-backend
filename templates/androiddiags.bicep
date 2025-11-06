@description('Name for the query pack')
param queryPackName string = 'android-queries'

// Root query pack
resource queryPack 'Microsoft.OperationalInsights/queryPacks@2025-02-01' = {
  name: queryPackName
  location: resourceGroup().location
  properties: {}
}

module vmHighLevel './query.bicep' = {
  name: 'vmHighLevel'
  params: {
    queryPackName: queryPackName
    displayName: 'Android VM processing - high level'
    queryDescription: 'High-level VM processing'
    query: '''
    pmtilesLogs_CL
    | where FilePath contains "svc"
    | order by TimeGenerated, RawData desc
    '''
  }
}

module vmDetail './query.bicep' = {
  name: 'vmDetail'
  params: {
    queryPackName: queryPackName
    displayName: 'Android VM processing - detailed logs'
    queryDescription: 'Low level logs of VM process'
    query: '''
    pmtilesLogs_CL
    | where FilePath !contains "svc"
    | order by TimeGenerated desc
    '''
  }
}

module functionApp './query.bicep' = {
  name: 'androidFunctionApp'
  params: {
    queryPackName: queryPackName
    displayName: 'Android function app logs'
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
    displayName: 'Android VM instance count'
    queryDescription: 'Capacity and VM instance counts for the VM scale set'
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
