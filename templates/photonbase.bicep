@description('Prefix for the deployment, e.g. aNN')
param prefix string

@description('Storage account name')
param storageName string


@description('Name of the storage container for downloads')
var downloadContainerName = 'downloads'

@description('Name of the storage container for uploads')
var uploadContainerName = 'uploads'

// UAMI for the VMSS
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: '${prefix}-uami'
  location: resourceGroup().location
}

// Storage account used for uploads
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

// Let the UAMI do as it pleases to that blob
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
