// Generalised alert
@description('Full ID of action group')
param actionGroupId string

@description('ID of Log Analytics workspace to monitor')
param logAnalyticsId string

@description('Name of the alert rule')
param alertRuleName string

@description('Display name')
param displayName string

@description('Description')
param alertDescription string

@description('Severity of the alert (0 is critical, 4 is lowest)')
param severity int

@description('Query to run for the alert')
param alertQuery string

@description('Interval for evaluation - defaults to 1 hour')
param evaluationInterval string = 'PT1H'

@description('Size for window, i.e. how much data is scanned - defaults to 1 hour')
param windowSize string = 'PT1H'

@description('Mute interval - defaults to 24 hours')
param muteInterval string = 'PT24H'

resource alertRule 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = {
  name: alertRuleName
  location: resourceGroup().location

  properties: {
    displayName: displayName
    description: alertDescription
    enabled: true
    severity: severity

    // Run every hour, looking back one hour
    evaluationFrequency: evaluationInterval
    windowSize: windowSize

    // Scope: the LAW workspace
    scopes: [
      logAnalyticsId
    ]

    // Criteria: query and threshold
    criteria: {
      allOf: [
        {
          query: alertQuery
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
        }
      ]
    }

    // Suppress duplicate alerts for the mute interval
    muteActionsDuration: muteInterval

    // Notify existing Action Group
    actions: {
      actionGroups: [
          actionGroupId
      ]
    }
  }
}
