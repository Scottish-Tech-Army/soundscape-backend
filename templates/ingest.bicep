@description('Suffix for the deployment, e.g. dev, prod, etc.')
param suffix string

@description('Name and RG of the Azure Container Registry')
param registryName string
param registryRG string

@description('Version tag for the images')
param versionTag string

@description('Ingest initial image')
param ingestInitialImage string = '${registryName}.azurecr.io/soundscape/ingest_simple:${versionTag}'

@description('Name of the Azure Container Registry UAMI - pre-existing, and should be supplied as a parameter really')
param registryUAMIName string = 'mi-ssp-dev-uks-acrpull'

@description('Registry URL')
param registryUrl string = '${registryName}.azurecr.io'

@description('Revision bump for the Container Apps')
param revisionSuffix string = utcNow('yyyyMMddHHmmss')

@description('Key vault name')
param keyVaultName string = '${suffix}-vlt-${uniqueString(resourceGroup().id)}'

@description('Name of the file share')
param fileShareName string = '${suffix}-fileshare'

@description('Azure DB for PostgreSQL Flexible Server name')
param dbServiceName string = '${suffix}-database'

@description('Regions to generate tiles for - planet except for testing. Typical valid values are "planet", "france-single" and "france-regions"')
//param genRegions string = 'planet'
//param genRegions string = 'france-regions'
param genRegions string = 'canada-single'

@description('Name of the virtual network')
param vnetName string = '${suffix}-vnet'

@description('Name of the subnet')
param containerInstanceSubnetName string = 'instance-subnet'

@description('Name of this one-off container group')
param containerGroupName string = 'ingest-group'

@description('Log Analytics workspace name')
param logAnalyticsWorkspaceName string = '${suffix}-law-${uniqueString(resourceGroup().id)}'

@description('Name of the storage account')
param storageAccountName string = '${suffix}${uniqueString(resourceGroup().id)}'

// Get the UAMI from the other subscription
resource registryUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: registryUAMIName
  scope: resourceGroup(registryRG)
}

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: '${suffix}-uami'
}

@description('User Assigned Managed Identity for ACR pull - resource ID')
var registryUamiResourceId = registryUami.id


// Storage account
resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageAccountName
}

var storageAccountKey string = storageAccount.listKeys().keys[0].value

// Log analytics workspace for diagnostics
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: logAnalyticsWorkspaceName
}

var primaryKey = logAnalytics.listKeys().primarySharedKey

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: vnet
  name: containerInstanceSubnetName
}

// New resources
resource ingestGroup 'Microsoft.ContainerInstance/containerGroups@2024-10-01-preview' = {
  name: containerGroupName
  location: resourceGroup().location
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${registryUamiResourceId}': {}
      '${uami.id}': {}
    }
  }
  properties: {
    osType: 'Linux'
    restartPolicy: 'Never'     // stops on completion
    subnetIds: [
      {
        id: subnet.id
      }
    ]
    imageRegistryCredentials: [
      {
        server: registryUrl
        identity: registryUamiResourceId
      }
    ]
    diagnostics: {
      logAnalytics: {
        workspaceId: logAnalytics.properties.customerId
        workspaceKey: primaryKey
        logType: 'ContainerInsights'
      }
    }
    containers: [
      {
        name: 'ingest-initial'
        properties: {
          image: ingestInitialImage
          resources: {
            limits: {
              cpu: 4
              memoryInGB: 16
            }
            requests: {
              cpu: 4
              memoryInGB: 16
            }
          }
          environmentVariables: [
            {
              name: 'revision'
              value: revisionSuffix
            }
            {
              name: 'POSTGIS_HOST'
              value: '${dbServiceName}.postgres.database.azure.com'
            }
            {
              name: 'POSTGIS_PORT'
              value: '5432'
            }
            {
              name: 'POSTGIS_USER'
              value: 'pgadmin'
            }
            {
              name: 'CLIENT_ID'
              value: uami.properties.clientId
            }
            {
              name: 'KEY_VAULT_NAME'
              value: keyVaultName
            }
            {
              name: 'POSTGIS_PASSWORD'
              secureValueReference: 'https://${keyVaultName}${environment().suffixes.keyvaultDns}/secrets/postgres-pw'
            }
            {
              name: 'POSTGIS_DBNAME'
              value: 'osm'
            }
            {
              name: 'GEN_REGIONS'
              value: genRegions
            }
            {
              name: 'TILES'
              value: '/${suffix}-tiles'
            }
          ]
          volumeMounts: [
            {
              name: 'fs-smb'
              mountPath: '/${suffix}-tiles'
            }
          ]
        }
      }
    ]
    volumes: [
      {
        name: 'fs-smb'
        azureFile:{
          shareName: fileShareName
          storageAccountName: storageAccountName
          storageAccountKey: storageAccountKey
        }
      }
    ]
  }
}
