@description('Shared Log Analytics workspace name')
param sharedLAW string

@description('Diags RG with alert group')
param diagsRG string

// Mirrored from certalerts.bicep so a bad threshold fails at the outermost
// boundary the deploy script passes into, rather than one module deeper.
@description('Days-to-expiry threshold for the certificate-expiry early warning')
@minValue(1)
param certAlertEarlyDays int

@description('Days-to-expiry threshold for the certificate-expiry imminent alert')
@minValue(1)
param certAlertImminentDays int

@description('Name of the pre-existing managed identity (created in sharedbase.bicep) the certificate-expiry rules use to read Azure Resource Graph')
param certAlertUamiName string

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

// Certificate-expiry alerts (early warning + imminent expiry) for every
// managed certificate on this shared Front Door profile. See
// templates/certalerts.bicep for the design this implements.
module certAlerts './certalerts.bicep' = {
  name: 'cert-alerts'
  params: {
    diagsRG: diagsRG
    logAnalyticsId: logAnalytics.id
    earlyDays: certAlertEarlyDays
    imminentDays: certAlertImminentDays
    certAlertUamiName: certAlertUamiName
  }
}
