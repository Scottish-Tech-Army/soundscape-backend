// Usage-metrics store for the historical-usage-superset feature (issue #35).
//
// Deployed into its own RG (soundscape-metrics). Stands up the long-term
// usage-metrics database that Superset is pointed at, plus the "shared reader"
// function app that pulls Front Door (iOS + photon) metrics from `shared-law`
// (which lives in the shared RG) into it. The Android reader is deployed
// separately, alongside the Android function apps; it writes to the same DB.
//
// This template only stands up resources. The table, the read-only Superset role,
// and the Entra writer roles for the reader UAMIs are created by the schema/access
// step (which runs SQL against the server) once the server exists.

@description('Name of the shared RG that holds the shared Log Analytics workspace')
param sharedRG string

@description('Existing shared Log Analytics workspace (Front Door logs), in the shared RG — the reader queries this for iOS + photon metrics')
param sharedLAW string

@description('Entra admin for the Postgres server (the deploying operator\'s UPN) — required so the schema step can create the readers\' Entra roles')
param pgAadAdminLogin string

@description('Entra admin object (principal) id for the Postgres server')
param pgAadAdminObjectId string

@description('Native Postgres admin password (break-glass / bootstrap). Minted server-side per deploy via newGuid() and mirrored into Key Vault; readers use Entra tokens, not this, so rotation is harmless.')
@secure()
param pgAdminPassword string = newGuid()

@description('Nightly run schedule (NCRONTAB). Default 03:00 daily.')
param triggerSchedule string = '0 3 * * *'

// Deterministic names seeded from the RG *and* region. Region-seeding means a
// later redeploy into a different region yields fresh names, so we never hit the
// Key Vault (90-day) / Log Analytics (14-day) soft-delete name lock when relocating.
var location            = resourceGroup().location
var suffix              = uniqueString(resourceGroup().id, location)
var uamiName            = 'metrics-uami'                  // no suffix: UAMIs free their name on delete
var pgServerName        = 'metrics-pg-${suffix}'          // globally unique, lowercase, <= 63 chars
var pgDatabaseName      = 'metrics'
var pgAdminLogin        = 'metricsadmin'                  // native (password) admin; break-glass only
var storageName         = 'metricstor${suffix}'          // <= 24 chars, lowercase alnum
var keyVaultName        = 'metkv${suffix}'               // <= 24 chars
var appInsightsName     = 'metrics-appinsights-${suffix}'
var diagLawName         = 'metrics-law-${suffix}'
var planName            = 'metrics-plan'                  // no suffix: App Service plans free their name on delete
var functionAppName     = 'usagemetrics-${suffix}'       // short name 'usagemetrics' → src/usagemetrics (matches functionapp.sh discovery)
var packageContainer    = 'metricsapp'

// Existing shared Log Analytics workspace (Front Door logs), in the shared RG —
// the data source the reader queries. Read-only, cross-RG.
resource sharedLaw 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: sharedLAW
  scope: resourceGroup(sharedRG)
}

// This RG's own workspace, for the function app's diagnostics (keeps the metrics
// stack self-contained rather than logging back into the shared workspace).
resource diagLaw 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: diagLawName
  location: location
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

// Dedicated, least-privilege identity for the shared reader: LA read + (later) DB write only.
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: location
}

// Let the reader run Log Analytics queries against the shared workspace. The
// grant must be created in the shared RG, so it goes via a module at that scope.
module lawReader 'metrics-lawreader.bicep' = {
  name: 'metrics-lawreader'
  scope: resourceGroup(sharedRG)
  params: {
    sharedLAW: sharedLAW
    principalId: uami.properties.principalId
  }
}

// Key Vault holding the native Postgres admin password (break-glass, written here)
// and the read-only Superset login password (populated later by the schema/access step).
resource keyVault 'Microsoft.KeyVault/vaults@2021-06-01-preview' = {
  name: keyVaultName
  location: location
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

// Mirror the native admin password into Key Vault so the schema step and any
// break-glass operator can retrieve it. newGuid() rotates it on every deploy;
// harmless because the readers authenticate with Entra tokens, not this password.
resource kvAdminSecret 'Microsoft.KeyVault/vaults/secrets@2021-06-01-preview' = {
  parent: keyVault
  name: 'pg-admin-password'
  properties: {
    value: pgAdminPassword
  }
}

// Let the deploying operator write the Superset password secret from
// scripts/metricsschema.sh. Key Vault is RBAC-auth, so Owner/Contributor alone does
// NOT grant data-plane secret writes — an explicit role is needed.
//
// IMPORTANT: this binds secret-write (and, via the SQL Entra admin, schema access) to
// the deploying operator's object id. metricsschema.sh MUST therefore be run by the
// *same* user who ran metricsdeploy.sh; a different operator would have neither the
// Key Vault grant nor Postgres admin rights.
resource operatorKvSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, pgAadAdminObjectId, 'kv-secrets-officer')
  scope: keyVault
  properties: {
    principalId: pgAadAdminObjectId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b86a8fe4-44ce-4948-aee5-eccb2c155cd7' // Key Vault Secrets Officer
    )
    principalType: 'User'
  }
}

// PostgreSQL Flexible Server — Burstable B1ms, the smallest managed SKU, with the
// minimum 32 GiB storage and 7-day backups (cost ~£12-13/mo). Azure SQL was the
// original choice but this subscription refuses new Microsoft.Sql server creation;
// Postgres is the agreed pivot. Mixed auth: Entra (for the reader UAMIs and the
// operator admin) + password (for the read-only Superset login). The native
// password admin is break-glass only; the schema step connects as the Entra admin.
//
// Note on cost: Flexible Server has no serverless auto-pause (unlike Azure SQL),
// so it bills continuously. B1ms + 32 GiB is the floor for a managed instance.
resource pgServer 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: pgServerName
  location: location
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '16'
    administratorLogin: pgAdminLogin
    administratorLoginPassword: pgAdminPassword
    authConfig: {
      activeDirectoryAuth: 'Enabled'   // reader UAMIs + operator admin
      passwordAuth: 'Enabled'          // required for the Superset read-only login
      tenantId: subscription().tenantId
    }
    storage: {
      storageSizeGB: 32                // minimum allowed
      autoGrow: 'Disabled'             // no surprise cost growth
    }
    backup: {
      backupRetentionDays: 7           // minimum; within retention backups are free
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
    createMode: 'Default'
  }
}

// The application database. Child resources of a Flexible Server cannot be created
// concurrently (the server rejects overlapping operations), so the database,
// firewall rule and Entra admin are chained with explicit dependsOn below.
resource pgDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: pgServer
  name: pgDatabaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// Allow Azure-internal callers (the reader function apps) to reach the server.
// The Superset client IP rule is added by the schema/access step.
resource fwAzureServices 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: pgServer
  name: 'AllowAllAzureIPs'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
  dependsOn: [ pgDatabase ]
}

// Entra admin = the deploying operator. Required so the schema step can create the
// readers' Entra roles (pgaadauth_create_principal_with_oid) and the Superset role.
resource pgAadAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = {
  parent: pgServer
  name: pgAadAdminObjectId
  properties: {
    principalType: 'User'
    principalName: pgAadAdminLogin
    tenantId: subscription().tenantId
  }
  dependsOn: [ fwAzureServices ]
}

// Storage account for the function app (package + AzureWebJobsStorage).
resource storage 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2022-09-01' = {
  name: 'default'
  parent: storage
}

resource packageContainerResource 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  name: packageContainer
  parent: blobService
}

var storageKey = storage.listKeys().keys[0].value

// Let the function app pull its package from the storage container using the UAMI.
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

// App Insights for the function, logging to this RG's own workspace.
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: diagLaw.id
  }
}

// FlexConsumption plan + function app for the shared reader. Code is published
// separately (functionapp publish); this creates the app and its settings.
resource plan 'Microsoft.Web/serverfarms@2021-02-01' = {
  name: planName
  kind: 'functionapp'
  location: location
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true // Linux
  }
}

resource functionApp 'Microsoft.Web/sites@2024-11-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux,flex'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    functionAppConfig: {
      runtime: {
        name: 'python'
        version: '3.12'
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 40
      }
      deployment: {
        storage: {
          type: 'BlobContainer'
          value: 'https://${storageName}.blob.${environment().suffixes.storage}/${packageContainer}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: uami.id
          }
        }
      }
    }
    siteConfig: {
      cors: {
        allowedOrigins: [
          'https://portal.azure.com'
        ]
      }
      appSettings: [
        { name: 'AzureWebJobsStorage',                   value: 'DefaultEndpointsProtocol=https;AccountName=${storageName};AccountKey=${storageKey};EndpointSuffix=${environment().suffixes.storage}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION',            value: '~4' }
        // Diagnostics
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING',  value: appInsights.properties.ConnectionString }
        { name: 'APPINSIGHTS_INSTRUMENTATIONKEY',         value: appInsights.properties.InstrumentationKey }
        { name: 'APPLICATIONINSIGHTS_ROLE_NAME',          value: functionAppName }
        // Identity used for both the Log Analytics query and the Postgres write
        { name: 'UAMI_CLIENT_ID',                         value: uami.properties.clientId }
        // Which source this reader pulls
        { name: 'METRICS_SOURCE',                         value: 'frontdoor' }
        // RG the data originates from (the source_rg label); the shared RG for
        // Front Door, which is stable across cutovers — not this metrics RG.
        { name: 'SOURCE_RG',                              value: sharedRG }
        // Log Analytics workspace to query (GUID used by the Logs query API)
        { name: 'LAW_CUSTOMER_ID',                        value: sharedLaw.properties.customerId }
        // Target database (Entra-token auth via the UAMI; no stored password). The
        // reader connects as its Entra role (PG_USER, == the UAMI name), using an
        // AAD access token for https://ossrdbms-aad.database.windows.net as the password.
        { name: 'PG_HOST',                                value: pgServer.properties.fullyQualifiedDomainName }
        { name: 'PG_DATABASE',                            value: pgDatabaseName }
        { name: 'PG_USER',                                value: uamiName }
        { name: 'PG_SSLMODE',                             value: 'require' }
        // Behaviour
        { name: 'SESSION_TIMEOUT_MINUTES',                value: '30' }
        { name: 'NIGHTLY_WINDOW_DAYS',                    value: '2' }
        { name: 'BACKFILL_WINDOW_DAYS',                   value: '30' }
        { name: 'TRIGGER_SCHEDULE',                       value: triggerSchedule }
      ]
    }
  }
}

output pgServerName string      = pgServerName
output pgServerFqdn string      = pgServer.properties.fullyQualifiedDomainName
output pgDatabaseName string    = pgDatabaseName
output keyVaultName string      = keyVaultName
output functionAppName string   = functionAppName
output metricsUamiName string   = uamiName
output metricsUamiClientId string = uami.properties.clientId
