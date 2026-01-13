@description('Name of the Action Group')
param actionGroupName string

@description('Short name (12 chars max)')
param shortName string

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  properties: {
    groupShortName: shortName
    enabled: true
  }
}
