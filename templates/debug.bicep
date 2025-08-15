@description('Suffix for the deployment, e.g. dev, prod, etc.')
param suffix string

@description('Name and RG of the Azure Container Registry')
param registryName string
param registryRG string

@description('Version tag for the images')
param versionTag string

@description('Debug image')
param debugImage string = '${registryName}.azurecr.io/soundscape/debug:${versionTag}'

@description('Name of the Azure Container Registry UAMI - pre-existing, and should be supplied as a parameter really')
param registryUAMIName string = 'mi-ssp-dev-uks-acrpull'

@description('Name of the Container Apps Environment (managed environment).')
param containerAppEnvName string = '${suffix}-container-apps-env'

@description('Registry URL')
param registryUrl string = '${registryName}.azurecr.io'

@description('Revision bump for the Container Apps')
param revisionSuffix string = utcNow('yyyyMMddHHmmss')

@description('Key vault name')
param keyVaultName string = '${suffix}-vlt-${uniqueString(resourceGroup().id)}'

@description('Azure DB for PostgreSQL Flexible Server name')
param dbServiceName string = '${suffix}-database'

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

// Container Apps Environment (existing)
resource containerAppEnv 'Microsoft.App/managedEnvironments@2025-02-02-preview' existing = {
  name: containerAppEnvName
}

// Debug app
resource debugApp 'Microsoft.App/containerapps@2025-02-02-preview' = {
  name: 'debug'
  location: resourceGroup().location
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
      '${registryUamiResourceId}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppEnv.id
    environmentId: containerAppEnv.id
    configuration: {
      secrets: [
        {
          name: 'postgres-pw'
          identity: uami.id
          keyVaultUrl: 'https://${keyVaultName}${environment().suffixes.keyvaultDns}/secrets/postgres-pw'
        }
      ]
      activeRevisionsMode: 'Single'
      registries: [
        {
          server: registryUrl
          identity: registryUamiResourceId
        }
      ]
    }
    template: {
      revisionSuffix: revisionSuffix
      containers: [
        {
          image: debugImage
          imageType: 'ContainerImage'
          name: 'debug'
          env: [
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
              name: 'POSTGIS_PASSWORD'
              secretRef: 'postgres-pw'
            }
            {
              name: 'POSTGIS_DBNAME'
              value: 'osm'
            }
          ]
          resources: {
            cpu: 1
            memory: '2Gi'
          }
          probes: []
          volumeMounts: [
            {
              volumeName: 'fs-smb'
              mountPath: '/${suffix}-tiles'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
      volumes: [
        {
          name: 'fs-smb'
          storageType: 'AzureFile'
          storageName: 'fs-smb'
        }
      ]
    }
  }
}
