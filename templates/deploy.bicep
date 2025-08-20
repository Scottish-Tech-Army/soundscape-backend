@description('Suffix for the deployment, e.g. dev, prod, etc.')
param suffix string

@description('Name and RG of the Azure Container Registry')
param registryName string
param registryRG string

@description('Version tag for the images')
param versionTag string

@description('Name of the Azure Container Registry UAMI - pre-existing, and should be supplied as a parameter really')
param registryUAMIName string = 'mi-ssp-dev-uks-acrpull'

@description('Key vault name')
param keyVaultName string = '${suffix}-vlt-${uniqueString(resourceGroup().id)}'

@description('Name of the Container Apps Environment (managed environment).')
param containerAppEnvName string = '${suffix}-container-apps-env'

@description('Registry URL')
param registryUrl string = '${registryName}.azurecr.io'

@description('Tilesrv image')
param tilesrvImage string = '${registryName}.azurecr.io/soundscape/tilesrv:${versionTag}'

@description('Ingest initial image')
param ingestInitialImage string = '${registryName}.azurecr.io/soundscape/ingest_simple:${versionTag}'

@description('Name of the virtual network')
param vnetName string = '${suffix}-vnet'

@description('Address range for the VNet')
param vnetAddressPrefix string = '10.1.0.0/16'

@description('Address range and name for the database subnet')
param dbSubnetPrefix string = '10.1.0.0/24'
param dbSubnetName string = 'db-subnet'

@description('Address range and name for the Container Apps subnet')
param containerAppSubnetPrefix string = '10.1.32.0/20'
param containerAppSubnetName string = 'app-subnet'

@description('Address range and name for the Container Instance subnet')
param containerInstanceSubnetPrefix string = '10.1.48.0/20'
param containerInstanceSubnetName string = 'instance-subnet'

@description('Address range and name for the Container Instance subnet')
param vmSubnetPrefix string = '10.1.16.0/20'
param vmSubnetName string = 'vm-subnet'

@description('Name of the storage account')
param storageAccountName string = '${suffix}${uniqueString(resourceGroup().id)}'

@description('Name of the file share')
param fileShareName string = '${suffix}-fileshare'

@description('Azure DB for PostgreSQL Flexible Server name')
param dbServiceName string = '${suffix}-database'

@description('Log Analytics workspace name')
param logAnalyticsWorkspaceName string = '${suffix}-law-${uniqueString(resourceGroup().id)}'

@description('DB admin password')
@secure()
param adminPassword string = newGuid() // Random string

@description('Revision bump for the Container Apps')
param revisionSuffix string = utcNow('yyyyMMddHHmmss')

@description('Regions to generate tiles for - planet except for testing. Typical valid values are "planet", "france-single" and "france-regions"')
//param genRegions string = 'planet'
//param genRegions string = 'france-regions'
param genRegions string = 'france-single'

//@description('Cron schedule for running the job - once per day at 6am')
//param scheduleCron string = '0 6 * * *'

// Get the UAMI from the other subscription
resource registryUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: registryUAMIName
  scope: resourceGroup(registryRG)
}

@description('User Assigned Managed Identity for ACR pull - resource ID')
var registryUamiResourceId = registryUami.id

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: '${suffix}-uami'
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

resource keyVaultSecret 'Microsoft.KeyVault/vaults/secrets@2022-11-01' = {
  parent: keyVault
  name: 'postgres-pw'
  properties: {
      value: adminPassword
  }
}

// Grant secrets read rights to the app's SAMI
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
        name: dbSubnetName
        properties: {
          addressPrefix: dbSubnetPrefix
          delegations: [
            {
              name: 'delegate-to-db'
              properties: {
                serviceName: 'Microsoft.DBforPostgreSQL/flexibleServers'
              }
            }
          ]
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Disabled'
        }
      }
      {
        name: containerAppSubnetName
        properties: {
          addressPrefix: containerAppSubnetPrefix
        }
      }
      {
        name: containerInstanceSubnetName
        properties: {
          addressPrefix: containerInstanceSubnetPrefix
          delegations: [
            {
              name: 'delegate-to-container-instances'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
            }
          ]
        }
      }
      {
        name: vmSubnetName
        properties: {
          addressPrefix: vmSubnetPrefix
        }
      }
    ]
  }
}

// Subnet for PostgreSQL private endpoint
var dbSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, dbSubnetName)
var containerSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, containerAppSubnetName)

// Private DNS Zone for PostgreSQL; name must exactly match this
resource pgDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.postgres.database.azure.com'
  location: 'global'
  properties: {}
}

// Link the private DNS zone to the virtual network
resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  name: 'link-to-vnet'
  location: 'global'
  parent: pgDnsZone
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

// Database
resource dbService 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: dbServiceName
  location: resourceGroup().location
  sku: {
    name: 'Standard_D2ds_v4'
    tier: 'GeneralPurpose'
  }
  properties: {
    version: '15'
    replica: {
      role: 'Primary'
    }
    storage: {
      storageSizeGB: 256
      // For some reason, this does not work, so sticking with regular premium SSD
      //iops: 3000
      //throughput: 125
      //type: 'PremiumV2_LRS' // Enables Premium SSD v2, which is cheaper
      autoGrow: 'Enabled'
    }
    network: {
      privateDnsZoneArmResourceId: pgDnsZone.id
      delegatedSubnetResourceId: dbSubnetId
      publicNetworkAccess: 'Disabled'
    }
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Enabled'
    }
    administratorLogin: 'pgadmin'
    administratorLoginPassword: adminPassword
    replicationRole: 'None'
  }
}

resource dbExtensions 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2025-01-01-preview' = {
  parent: dbService
  name: 'azure.extensions'
  properties: {
    value: 'postgis,hstore'
    source: 'user-override'
  }
}

// Storage account
resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: resourceGroup().location
  sku: {
    name: 'Premium_LRS'
  }
  kind: 'FileStorage'
}

var storageAccountKey string = storageAccount.listKeys().keys[0].value

resource storageFileService 'Microsoft.Storage/storageAccounts/fileServices@2025-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource storageFileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-01-01' = {
  parent: storageFileService
  name: fileShareName
  properties: {
    fileSharePaidBursting: {
      paidBurstingEnabled: false
    }
    accessTier: 'Premium'
    shareQuota: 500
    enabledProtocols: 'SMB'
  }
}

// Container Apps Environment
resource containerAppEnv 'Microsoft.App/managedEnvironments@2025-02-02-preview' = {
  name: containerAppEnvName
  location: resourceGroup().location
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: containerSubnetId
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// Storage attachment
resource caeStorage 'Microsoft.App/managedEnvironments/storages@2025-02-02-preview' = {
  parent: containerAppEnv
  name: 'fs-smb'
  properties: {
    azureFile: {
      accountName: storageAccountName
      shareName: fileShareName
      accessMode: 'ReadWrite'
      accountKey: storageAccountKey
    }
  }
}

// Log analytics workspace for diagnostics
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2020-08-01' = {
  name: logAnalyticsWorkspaceName
  location: resourceGroup().location
  properties: {}
}

// Grant UAMI rights to the LAW, so the AMA can write to it
resource roleAssign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(logAnalytics.id, 'ama-data-collector')
  scope: logAnalytics
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b0db2e35-c5f2-5753-8e1a-19ef176ddf8e'   // Azure Monitor Data Collector
    )
    principalId: uami.properties.principalId
  }
}

// Create a table for ingest logs
resource customTable 'Microsoft.OperationalInsights/workspaces/tables@2025-02-01' = {
  name: 'IngestLogs_CL' // "_CL" suffix is required
  parent: logAnalytics
  properties: {
    plan: 'Basic'
    schema: {
      name: 'IngestLogs_CL'
      displayName: 'Ingest Logs'
      description: 'Custom table for ingesting logs'
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

// Azure Container Apps Job
// Manually invoked initial job
resource ingestInitialAppJob 'Microsoft.App/jobs@2024-03-01' = {
  name: 'ingest-initial'
  location: resourceGroup().location
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${registryUamiResourceId}': {}
      '${uami.id}': {}
    }
  }
  dependsOn: [
    vaultRole
  ]
  properties: {
    configuration: {
      registries: [
        {
          server: registryUrl
          identity: registryUamiResourceId
        }
      ]
      secrets: [
        {
          name: 'postgres-pw'
          identity: uami.id
          keyVaultUrl: 'https://${keyVaultName}${environment().suffixes.keyvaultDns}/secrets/postgres-pw'
        }
      ]
      replicaTimeout: 86400 // 24 hours
      triggerType: 'Manual'
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
    }
    environmentId: containerAppEnv.id
    template: {
      containers: [
        {
          name: 'ingest-initial'
          image: ingestInitialImage
          resources: {
            cpu: 2
            memory: '4Gi'
          }
          env: [
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
              name: 'POSTGIS_PASSWORD'
              secretRef: 'postgres-pw'
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
          probes: []
          volumeMounts: [
            {
              volumeName: 'fs-smb'
              mountPath: '/${suffix}-tiles'
            }
          ]
        }
      ]
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


// Container Apps
resource tilesrvApp 'Microsoft.App/containerapps@2025-02-02-preview' = {
  name: 'tilesrv'
  location: resourceGroup().location
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${registryUamiResourceId}': {}
      '${uami.id}': {}
    }
  }
  dependsOn: [
    vaultRole
  ]
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
      ingress: {
        external: true
        targetPort: 8080
        exposedPort: 0
        transport: 'Auto'
        traffic: [
          {
            weight: 100
            latestRevision: true
            label: 'blue'
          }
        ]
        allowInsecure: true
      }
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
          image: tilesrvImage
          imageType: 'ContainerImage'
          name: 'tilesrv'
          env: [
            {
              name: 'APP_PORT'
              value: '8080'
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
              name: 'POSTGIS_PASSWORD'
              secretRef: 'postgres-pw'
            }
            {
              name: 'POSTGIS_DBNAME'
              value: 'osm'
            }
          ]
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          probes: []
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 20
        rules: [
          {
            name: 'scalerule'
            http: {
              metadata: {
                concurrentRequests: '35'
              }
            }
          }
        ]
      }
      volumes: []
    }
  }
}
