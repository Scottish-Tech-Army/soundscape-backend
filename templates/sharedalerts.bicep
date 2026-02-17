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
module tileErrorAlert './alert.bicep' = {
  name: 'tile-error-alert'
  params: {
    alertRuleName: 'tile-error-alert'
    diagsRG: diagsRG
    logAnalyticsId: logAnalytics.id
    displayName: 'iOS tile request failures'
    alertDescription: 'iOS tile requests have been failing'
    severity: 2
    alertQuery: '''
    AzureDiagnostics
    | where Category == "FrontDoorAccessLog"
    | where httpStatusCode_s != 200
    | where requestUri_s startswith "https://prd2."
    | where requestUri_s contains "/tiles/"
    '''
  }
}

// Alert rule for non-zero errors in the tile requests
module photonErrorAlert './alert.bicep' = {
  name: 'photon-error-alert'
  params: {
    alertRuleName: 'photon-error-alert'
    diagsRG: diagsRG
    logAnalyticsId: logAnalytics.id
    displayName: 'Photon search request failures'
    alertDescription: 'Photon search requests have been failing'
    severity: 2
    alertQuery: '''
    AzureDiagnostics
    | where Category == "FrontDoorAccessLog"
    | where httpStatusCode_s != 200
    | where requestUri_s startswith "https://photon."
    | where requestUri_s contains "/photon/"
    '''
  }
}
