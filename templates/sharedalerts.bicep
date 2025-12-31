@description('Shared Log Analytics workspace name')
param sharedLAW string

// Removed for now - alert disabled at bottom
@description('Diags RG with alert group')
param diagsRG string

/*
 * Log Analytics Workspace
 */
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: sharedLAW
  location: resourceGroup().location
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

// Alert rule for non-zero errors in the tile requests
module vmErrorAlert './alert.bicep' = {
  name: 'tile-error-alert'
  params: {
    alertRuleName: 'tile-error-alert'
    diagsRG: diagsRG
    logAnalyticsId: logAnalytics.id
    displayName: 'iOS tile request failures'
    alertDescription: 'iOS tile requests have been failing'
    severity: 1
    alertQuery: '''
    AzureDiagnostics
    | where Category == "FrontDoorAccessLog"
    | where httpStatusCode_s != 200
    | where requestUri_s contains "tiles"
    '''
  }
}
