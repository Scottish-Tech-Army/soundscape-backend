@description('Escaped KQL query')
param kqlQuery string

@description('Display name for the workbook')
param workbookDisplayName string

@description('logAnalytics workspace ID')
param logAnalyticsId string

@description('Workbook title')
param title string

// We default to maximum value of 1, but allow this to be left out
@description('ySettings for the graph')
param ySettings string = '{"max": 1}'

@description('Raw JSON workbook')
var rawJson = loadTextContent('workbook.json')
var tmpJson1 = replace(rawJson, '{{LAW_ID}}', logAnalyticsId)
var tmpJson2 = replace(tmpJson1, '{{TITLE}}', title)
var tmpJson3 = replace(tmpJson2, '{{YSETTINGS}}', ySettings)

@description('JSON workbook with substitutions')
var serializedData = replace(tmpJson3, '"{{QUERY}}"', kqlQuery)

resource workbook 'microsoft.insights/workbooks@2022-04-01' = {
  name: guid(resourceGroup().id, workbookDisplayName)
  location: resourceGroup().location
  kind: 'shared'
  properties: {
    displayName: workbookDisplayName
    serializedData: serializedData
    version: '1.0'
    sourceId: 'azure monitor'
    category: 'workbook'
  }
}

output id string = workbook.id
output title string = title
