// Parameters required for all deployments
param prefix string
param triggerAppName string
param metricAppName string
param storageName string
param vmssName string
param logAnalyticsWorkspaceName string
param triggerSchedule string

@description('Trigger type - must be SCALE or REIMAGE')
@allowed([
  'SCALE'
  'REIMAGE'
])
param triggerType string

// Parameters only required when deploying the Cloudflare metrics function app.
// If cfMetricsAppName is empty (the default) the app and all its associated resources
// are not created. This allows functions.bicep to be reused across deployments that
// do not need Cloudflare metrics (e.g. iOS).
param cfMetricsAppName string = ''
param keyVaultName string = ''   // Key vault containing cloudflare-api-token and cloudflare-account-id
param pmtilesBucket string = ''  // Cloudflare worker / R2 bucket name for tile data
param extractsBucket string = '' // Cloudflare worker / R2 bucket name for offline extracts

// Plans - every function app needs one.
var triggerPlanName    = '${prefix}-trigger-plan'
var metricPlanName     = '${prefix}-metric-plan'
var cfMetricsPlanName  = '${prefix}-cfmetrics-plan'

@description('Metric schedule in cron format, e.g. "*/5 * * * *" for every five minutes')
var metricSchedule string = '*/5 * * * *'

@description('Cloudflare metrics schedule - 10 minutes past the hour so that the full hour of R2 storage data is available from the Cloudflare analytics API')
var cfMetricsSchedule string = '10 * * * *'

// Existing storage account
resource storage 'Microsoft.Storage/storageAccounts@2022-09-01' existing = {
  name: storageName
}

// Grab the first storage account key
var storageKey = storage.listKeys().keys[0].value

// Blob service and storage in that account for the function app code
var triggerContainerName    = 'triggerapp'
var metricContainerName     = 'metricapp'
var cfMetricsContainerName  = 'cfmetricsapp'

@description('App insights name')
var appInsightsName string = '${prefix}-appinsights-${uniqueString(resourceGroup().id)}'

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2022-09-01' existing = {
  name: 'default'
  parent: storage
}

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: '${prefix}-uami'
}

// Get LA workspace
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: logAnalyticsWorkspaceName
}

// Application Insights
resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2024-03-01' existing = {
  name: vmssName
}

resource triggerContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  name: triggerContainerName
  parent: blobService
}

resource metricContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  name: metricContainerName
  parent: blobService
}

resource cfMetricsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = if (cfMetricsAppName != '') {
  name: cfMetricsContainerName
  parent: blobService
}

// 1a - UAMI permissions on the storage account
resource blobDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, 'blob-contributor', uami.id)
  scope: storage
  properties: {
    principalId: uami.properties.principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor
    )
    principalType: 'ServicePrincipal'
  }
}

resource queueDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, 'queue-contributor', uami.id)
  scope: storage
  properties: {
    principalId: uami.properties.principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor
    )
    principalType: 'ServicePrincipal'
  }
}

// 2) Consumption (Dynamic) plan
resource triggerPlan 'Microsoft.Web/serverfarms@2021-02-01' = {
  name: triggerPlanName
  kind: 'functionapp'
  location: resourceGroup().location
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true // Linux
  }
}

resource metricPlan 'Microsoft.Web/serverfarms@2021-02-01' = {
  name: metricPlanName
  kind: 'functionapp'
  location: resourceGroup().location
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true // Linux
  }
}

// 3) Function App
resource triggerApp 'Microsoft.Web/sites@2024-11-01' = {
  name: triggerAppName
  location: resourceGroup().location
  kind: 'functionapp,linux,flex'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    serverFarmId: triggerPlan.id
    functionAppConfig: {
      runtime: {
        name: 'python'
        version: '3.12'
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 40 // Seems to be required, and 40 is minimum value
      }
      deployment: {
        storage: {
          // Package location
          type: 'BlobContainer' // Pick most recent blob from this container
          value: 'https://${storageName}.blob.${environment().suffixes.storage}/${triggerContainerName}'

          // Auth model for the package fetch (UAMI)
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: uami.id
            // storageAccountConnectionStringName not required when using UAMI
          }
        }
      }
    }
    siteConfig: {
      cors: {
        allowedOrigins: [
          'https://portal.azure.com'    // allow portal XHR calls, required for testing
        ]
      }
      appSettings: [
        { name:  'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storageName};AccountKey=${storageKey};EndpointSuffix=${environment().suffixes.storage}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION',      value: '~4' }

        // Diags settings
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING',  value: appInsights.properties.ConnectionString }
        { name: 'APPINSIGHTS_INSTRUMENTATIONKEY',   value: appInsights.properties.InstrumentationKey }
        { name: 'APPLICATIONINSIGHTS_ROLE_NAME',    value: triggerAppName }

        // Variables passed to the code
        { name: 'UAMI_CLIENT_ID',                   value: uami.properties.clientId }
        { name: 'AZURE_SUBSCRIPTION_ID',            value: subscription().subscriptionId }
        { name: 'VMSS_RESOURCE_GROUP',              value: resourceGroup().name }
        { name: 'VMSS_NAME',                        value: vmssName }
        { name: 'VMSS_RESOURCE_ID',                 value: vmss.id }
        { name: 'TRIGGER_SCHEDULE',                 value: triggerSchedule }
        { name: 'TRIGGER_TYPE',                     value: triggerType }
      ]
    }
  }
}

resource metricApp 'Microsoft.Web/sites@2024-11-01' = {
  name: metricAppName
  location: resourceGroup().location
  kind: 'functionapp,linux,flex'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    serverFarmId: metricPlan.id
    functionAppConfig: {
      runtime: {
        name: 'python'
        version: '3.12'
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 40 // Seems to be required, and 40 is minimum value
      }
      deployment: {
        storage: {
          // Package location
          type: 'BlobContainer' // Pick most recent blob from this container
          value: 'https://${storageName}.blob.${environment().suffixes.storage}/${metricContainerName}'

          // Auth model for the package fetch (UAMI)
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: uami.id
            // storageAccountConnectionStringName not required when using UAMI
          }
        }
      }
    }
    siteConfig: {
      cors: {
        allowedOrigins: [
          'https://portal.azure.com'    // allow portal XHR calls, required for testing
        ]
      }
      appSettings: [
        { name:  'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storageName};AccountKey=${storageKey};EndpointSuffix=${environment().suffixes.storage}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION',      value: '~4' }
        // Diags settings
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING',  value: appInsights.properties.ConnectionString }
        { name: 'APPINSIGHTS_INSTRUMENTATIONKEY',   value: appInsights.properties.InstrumentationKey }
        { name: 'APPLICATIONINSIGHTS_ROLE_NAME',    value: triggerAppName }
        // Variables passed to the code
        { name: 'UAMI_CLIENT_ID',                   value: uami.properties.clientId }
        { name: 'AZURE_SUBSCRIPTION_ID',            value: subscription().subscriptionId }
        { name: 'VMSS_RESOURCE_GROUP',              value: resourceGroup().name }
        { name: 'VMSS_NAME',                        value: vmssName }
        { name: 'VMSS_RESOURCE_ID',                 value: vmss.id }
        { name: 'TRIGGER_SCHEDULE',                 value: metricSchedule }
      ]
    }
  }
}

resource cfMetricsPlan 'Microsoft.Web/serverfarms@2021-02-01' = if (cfMetricsAppName != '') {
  name: cfMetricsPlanName
  kind: 'functionapp'
  location: resourceGroup().location
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true // Linux
  }
}

resource cfMetricsApp 'Microsoft.Web/sites@2024-11-01' = if (cfMetricsAppName != '') {
  name: cfMetricsAppName
  location: resourceGroup().location
  kind: 'functionapp,linux,flex'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    serverFarmId: cfMetricsPlan.id
    keyVaultReferenceIdentity: uami.id  // Which UAMI to use when resolving KV references in app settings
    functionAppConfig: {
      runtime: {
        name: 'python'
        version: '3.12'
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 40
      }
      deployment: {
        storage: {
          type: 'BlobContainer'
          value: 'https://${storageName}.blob.${environment().suffixes.storage}/${cfMetricsContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: uami.id
          }
        }
      }
    }
    siteConfig: {
      cors: {
        allowedOrigins: [
          'https://portal.azure.com'
        ]
      }
      appSettings: [
        { name: 'AzureWebJobsStorage',                    value: 'DefaultEndpointsProtocol=https;AccountName=${storageName};AccountKey=${storageKey};EndpointSuffix=${environment().suffixes.storage}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION',            value: '~4' }
        // Diags settings
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING',  value: appInsights.properties.ConnectionString }
        { name: 'APPINSIGHTS_INSTRUMENTATIONKEY',         value: appInsights.properties.InstrumentationKey }
        { name: 'APPLICATIONINSIGHTS_ROLE_NAME',          value: cfMetricsAppName }
        // Cloudflare credentials
        { name: 'CF_API_TOKEN',                           value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=cloudflare-api-token)' }
        { name: 'CF_ACCOUNT_ID',                          value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=cloudflare-account-id)' }
        // Worker and bucket names
        { name: 'CF_PMTILES_SCRIPT',                      value: pmtilesBucket }
        { name: 'CF_EXTRACTS_SCRIPT',                     value: extractsBucket }
        // Schedule
        { name: 'TRIGGER_SCHEDULE',                       value: cfMetricsSchedule }
      ]
    }
  }
}

// Optional: Diagnostic settings from Function App to Log Analytics (platform logs/metrics)
resource funcDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${prefix}-func-diag'
  scope: triggerApp
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'FunctionAppLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output triggerAppId string = triggerApp.id
