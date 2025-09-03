@description('Name of the query pack to add the saved query to')
param queryPackName string

@description('Display name for the saved query')
param displayName string

@description('Description for the saved query')
param queryDescription string

@description('Query in KQL')
param query string

@description('Category for the saved query')
var categoryName string = 'applications'

resource queryPack 'Microsoft.OperationalInsights/queryPacks@2025-02-01' existing = {
  name: queryPackName
}

resource savedQuery 'Microsoft.OperationalInsights/queryPacks/queries@2025-02-01' = {
  name: guid(resourceGroup().id, displayName)
  parent: queryPack
  properties: {
    displayName: displayName
    body: query
    description: queryDescription
    related: {
      categories: [
        categoryName
      ]
    }
  }
}
