@description('Prefix for the deployment, e.g. dev, prod, etc.')
param prefix string

@description('Name and RG of the Azure Container Registry')
param registryName string
param registryRG string

@description('Version tag for the images')
param versionTag string

@description('Storage account name')
param storageName string

@description('Name of the Azure Container Registry UAMI - pre-existing, and should be supplied as a parameter really')
// FIXME: hardcoded
param registryUAMIName string = 'mi-ssp-dev-uks-acrpull'

// These two are params because for one reason or another they cannot be vars.
// The DB admin password gets reset (but plumbed through) on every redeployment, to a random value.
// This is declared as a param because secure params cannot be vars.
@description('DB admin password')
@secure()
param adminPassword string = newGuid() // Random string

// utcNow is only valid as a param default. This is to force a revision on each deployment.
@description('Revision bump for the Container Apps')
param revisionSuffix string = utcNow('yyyyMMddHHmmss')

// Variables that are calculated from the above
@description('Key vault name')
var keyVaultName string = '${prefix}-vlt-${uniqueString(resourceGroup().id)}'

@description('Name of the Container Apps Environment (managed environment).')
var containerAppEnvName string = '${prefix}-container-apps-env'

@description('Registry URL')
var registryUrl string = '${registryName}.azurecr.io'

@description('Tilesrv image')
var tilesrvImage string = '${registryName}.azurecr.io/soundscape/tilesrv:${versionTag}'

//@description('Metrics image')
//var metricsImage string = '${registryName}.azurecr.io/soundscape/metrics:${versionTag}'

@description('Name of the virtual network')
var vnetName string = '${prefix}-vnet'

@description('Address range for the VNet')
var vnetAddressPrefix string = '10.1.0.0/16'

@description('Address range and name for the database subnet')
var dbSubnetPrefix string = '10.1.0.0/24'
var dbSubnetName string = 'db-subnet'

@description('Address range and name for the Container Apps subnet')
var containerAppSubnetPrefix string = '10.1.32.0/20'
var containerAppSubnetName string = 'app-subnet'

@description('Address range and name for the VM subnet')
var vmSubnetPrefix string = '10.1.16.0/20'
var vmSubnetName string = 'vm-subnet'

@description('Azure DB for PostgreSQL Flexible Server name')
var dbServiceName string = '${prefix}-db-${uniqueString(resourceGroup().id)}'

@description('Log Analytics workspace name')
var logAnalyticsWorkspaceName string = '${prefix}-law-${uniqueString(resourceGroup().id)}'

@description('App insights name')
var appInsightsName string = '${prefix}-appinsights-${uniqueString(resourceGroup().id)}'

@description('Tilesrv Container App name')
var tilesrvAppName string = '${prefix}-tilesrv-${uniqueString(resourceGroup().id)}'

@description('Name of the storage container for downloads')
var downloadContainerName = 'downloads'

@description('Name of the storage container for uploads')
var uploadContainerName = 'uploads'

// Get the UAMI from the other subscription
resource registryUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: registryUAMIName
  scope: resourceGroup(registryRG)
}

@description('User Assigned Managed Identity for ACR pull - resource ID')
var registryUamiResourceId = registryUami.id

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: '${prefix}-uami'
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
// https://learn.microsoft.com/en-us/azure/templates/microsoft.dbforpostgresql/flexibleservers
resource dbService 'Microsoft.DBforPostgreSQL/flexibleServers@2025-06-01-preview' = {
  name: dbServiceName
  location: resourceGroup().location
  sku: {
    name: 'Standard_D2ds_v5' // 2 vCPU, 8GB RAM
    tier: 'GeneralPurpose'
  }
  properties: {
    version: '16'
    replica: {
      role: 'Primary'
    }
    storage: {
      // For Premium SSD v1, remove iops and throughput, and turn autoGrow back on
      storageSizeGB: 850
      iops: 12000
      throughput: 500
      // https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-storage-premium-ssd-v2
      type: 'PremiumV2_LRS' // Enables Premium SSD v2, which is cheaper
      //autoGrow: 'Enabled' // Not supported for Premium SSD v2
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

// Send diagnostics log from DB to Log Analytics
resource dbDiags 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-postgres-logs'
  scope: dbService
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'PostgreSQLLogs'
        enabled: true
      }
      {
        category: 'PostgreSQLFlexSessions'
        enabled: true
      }
      {
        category: 'PostgreSQLFlexTableStats'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
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
    appInsightsConfiguration: {
      connectionString: appInsights.properties.ConnectionString
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

// Log analytics workspace for diagnostics
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2020-08-01' = {
  name: logAnalyticsWorkspaceName
  location: resourceGroup().location
  properties: {}
}

// Create AppTraces table using Analytics plan. We must do this before the app insights resoure is created,
// hence the dependency below.
resource appTracesTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: logAnalytics
  name: 'AppTraces'
  properties: {
    plan: 'Analytics'
  }
}

// Application Insights linked to the existing Log Analytics workspace
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: resourceGroup().location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
  dependsOn: [
    appTracesTable
  ]
}

// Grant UAMI rights to publish to LAW
resource roleAssignMetrics 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(logAnalytics.id, 'ama-metrics-publisher')
  scope: logAnalytics
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '3913510d-42f4-4e42-8a64-420c390055eb' // Monitoring Metrics Publisher
    )
    principalId: uami.properties.principalId
  }
}

// Custom logs imply that you need this too
resource roleAssignLogs 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(logAnalytics.id, 'ama-log-writer')
  scope: logAnalytics
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '73c42c96-874c-492b-b04d-ab87d138a893' // Log Analytics Contributor
    )
    principalId: uami.properties.principalId
  }
}

// Create a table for ingest logs
resource customTable 'Microsoft.OperationalInsights/workspaces/tables@2025-02-01' = {
  name: 'IngestLogs_CL' // "_CL" suffix is required
  parent: logAnalytics
  properties: {
    plan: 'Analytics'
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

// Container Apps
resource tilesrvApp 'Microsoft.App/containerapps@2025-02-02-preview' = {
  name: tilesrvAppName
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
            { name: 'APP_PORT',            value: '8080' }
            { name: 'POSTGIS_HOST',        value: '${dbServiceName}.postgres.database.azure.com' }
            { name: 'POSTGIS_PORT',        value: '5432' }
            { name: 'POSTGIS_USER',        value: 'pgadmin' }
            { name: 'POSTGIS_PASSWORD',    secretRef: 'postgres-pw' }
            { name: 'POSTGIS_DBNAME',      value: 'osm' }
            { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
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
        maxReplicas: 5
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

// Storage account used by function app and uploads
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

resource uploadContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  name: uploadContainerName
  parent: blobService
}

resource downloadContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  name: downloadContainerName
  parent: blobService
}

