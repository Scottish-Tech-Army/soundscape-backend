@description('Prefix for the deployment, e.g. aNN')
param prefix string

@description('Storage account name')
param storageName string

// Variables that are calculated from the above
@description('Key vault name')
var keyVaultName string = '${prefix}-vlt-${uniqueString(resourceGroup().id)}'

@description('Name of the virtual network')
var vnetName string = '${prefix}-vnet'

@description('Address range for the VNet')
var vnetAddressPrefix string = '10.1.0.0/16'

@description('Address range and name for the VM subnet')
var vmSubnetPrefix string = '10.1.16.0/20'
var vmSubnetName string = 'vm-subnet'

@description('Log Analytics workspace name')
var logAnalyticsWorkspaceName string = '${prefix}-law-${uniqueString(resourceGroup().id)}'

@description('App insights name')
var appInsightsName string = '${prefix}-appinsights-${uniqueString(resourceGroup().id)}'

@description('Name of the storage container for downloads')
var downloadContainerName = 'downloads'

@description('Name of the storage container for uploads')
var uploadContainerName = 'uploads'

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: '${prefix}-uami'
  location: resourceGroup().location
}

// Azure Key Vault
resource keyVault 'Microsoft.KeyVault/vaults@2021-06-01-preview' = {
  name: keyVaultName
  location: resourceGroup().location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    accessPolicies: []
    enableRbacAuthorization: true
  }
}

// Grant secrets read rights to the app's UAMI
resource vaultRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, 'vaultaccess')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
    principalId: uami.properties.principalId
  }
}

// Set up an NSG for the VM subnet that denies all inbound traffic
resource vmNsg 'Microsoft.Network/networkSecurityGroups@2022-09-01' = {
  name: 'vm-nsg'
  location: resourceGroup().location
  properties: {
    securityRules: [
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// vnet
resource vnet 'Microsoft.Network/virtualNetworks@2022-09-01' = {
  name: vnetName
  location: resourceGroup().location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: vmSubnetName
        properties: {
          addressPrefix: vmSubnetPrefix

          networkSecurityGroup: {
            id: vmNsg.id
          }
        }
      }
    ]
  }
}

// Log analytics workspace for diagnostics
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2020-08-01' = {
  name: logAnalyticsWorkspaceName
  location: resourceGroup().location
  properties: {}
}

// Create AppTraces table using Analytics plan. We must do this before the app insights resoure is created,
// hence the dependency below.
resource appTracesTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: logAnalytics
  name: 'AppTraces'
  properties: {
    plan: 'Analytics'
  }
}

// Application Insights linked to the existing Log Analytics workspace
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: resourceGroup().location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
  dependsOn: [
    appTracesTable
  ]
}

// Grant UAMI rights to publish to LAW
resource roleAssignMetrics 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(logAnalytics.id, 'ama-metrics-publisher')
  scope: logAnalytics
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '3913510d-42f4-4e42-8a64-420c390055eb' // Monitoring Metrics Publisher
    )
    principalId: uami.properties.principalId
  }
}

// Custom logs imply that you need this too
resource roleAssignLogs 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(logAnalytics.id, 'ama-log-writer')
  scope: logAnalytics
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '73c42c96-874c-492b-b04d-ab87d138a893' // Log Analytics Contributor
    )
    principalId: uami.properties.principalId
  }
}

// Create a table for pmtiles logs
resource customTable 'Microsoft.OperationalInsights/workspaces/tables@2025-02-01' = {
  name: 'pmtilesLogs_CL' // "_CL" suffix is required
  parent: logAnalytics
  properties: {
    plan: 'Analytics'
    schema: {
      name: 'pmtilesLogs_CL'
      displayName: 'pmtiles Logs'
      description: 'Custom table for pmtiles logs'
      columns: [
        {
          name: 'TimeGenerated'
          type: 'DateTime'
        }
        {
          name: 'RawData'
          type: 'String'
        }
        {
          name: 'FilePath'
          type: 'string'
        }
        {
          name: 'Computer'
          type: 'string'
        }
      ]
    }
  }
}

// Storage account used by function app and uploads
resource storage 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageName
  location: resourceGroup().location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2022-09-01' = {
  name: 'default'
  parent: storage
}

resource downloadContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  name: downloadContainerName
  parent: blobService
}

resource uploadContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  name: uploadContainerName
  parent: blobService
}
