@description('ACR name')
param registryName string

@description('Shared UAMI name, for UAMI with AcrPull role')
param uamiName string

@description('Shared Log Analytics workspace name')
param sharedLAW string

/*
 * Azure Container Registry (Basic)
 */
resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: registryName
  location: resourceGroup().location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

// Create the UAMI in this RG
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: resourceGroup().location
}

// Assign AcrPull to the UAMI on the ACR
resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, uami.id, 'acrpull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull
    )
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

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
