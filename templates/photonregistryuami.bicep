// So we need to grant rights for the main UAMI to assign the registry UAMI, in order to update the VMSS.
// This is scoped against the registry RG.
@description('Prefix for the deployment, e.g. aNN')
param prefix string

@description('Resource group containing the main UAMI (used by the Function App)')
param mainRG string

@description('Name of the registry UAMI (attached to the VMSS)')
param registryUAMIName string

// UAMI that we grant rights to
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: '${prefix}-uami'
  scope: resourceGroup(mainRG)
}

// Existing registry UAMI (this is the scope we grant on)
resource registryUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: registryUAMIName
}

// Grant Managed Identity Operator on registry-uami to main-uami
resource allowAssignRegistryUami 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registryUami.id, uami.id, 'assign-registry-uami')
  scope: registryUami
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'f1a07417-d97a-45cb-824c-7a7467783830' // Managed Identity Operator
    )
    principalId: uami.properties.principalId
  }
}
