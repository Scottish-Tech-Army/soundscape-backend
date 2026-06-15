// Grants a reader UAMI Log Analytics Reader on the shared Front Door workspace.
// Deployed as a module at the shared RG scope from metricsdb.bicep, because a
// role assignment must be created in the same RG as the resource it scopes to.

@description('Shared Log Analytics workspace name (in this — the shared — RG)')
param sharedLAW string

@description('Principal id of the reader UAMI to grant read access')
param principalId string

resource sharedLaw 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: sharedLAW
}

resource lawReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sharedLaw.id, principalId, 'law-reader')
  scope: sharedLaw
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '73c42c96-874c-492b-b04d-ab87d138a893' // Log Analytics Reader
    )
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
