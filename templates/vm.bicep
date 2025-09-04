// Variables that must be passed in
@description('Prefix for the deployment, e.g. dev, prod, etc.')
param prefix string

@description('Function app name')
param functionAppName string

@description('Storage account name')
param storageName string

// Variables that could probably be changed
@description('Regions to generate tiles for - planet except for testing. Typical valid values are "planet", "france-single" and "france-regions"')
param genRegions string = 'planet'
//param genRegions string = 'europe'
//param genRegions string = 'canada'

// From here on, things that never change, so just vars
@description('ssh key')
var sshPublicKey string = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK3Nyaoy93lLUDkZY7V0dh2WdA9E8Zl0R+JLuR8EGwfJ'

@description('Name of the virtual network and subnet')
var vnetName string = '${prefix}-vnet'
var vmSubnetName string = 'vm-subnet'

@description('Azure DB for PostgreSQL Flexible Server name')
var dbServiceName string = '${prefix}-db-${uniqueString(resourceGroup().id)}'

@description('Key vault name')
var keyVaultName string = '${prefix}-vlt-${uniqueString(resourceGroup().id)}'

@description('Log Analytics workspace name')
var logAnalyticsWorkspaceName string = '${prefix}-law-${uniqueString(resourceGroup().id)}'

@description('App insights name')
var appInsightsName string = '${prefix}-appinsights-${uniqueString(resourceGroup().id)}'

@description('Tilesrv Container App name')
var tilesrvAppName string = '${prefix}-tilesrv-${uniqueString(resourceGroup().id)}'

@description('VM size supporting ephemeral NVMe OS disk')
//var vmSize string = 'Standard_L8s_v3'
//var vmSize string = 'Standard_L8s'
//var vmSize string = 'Standard_E4ds_v4'
//var vmSize string = 'Standard_E8ds_v4'
//var vmSize string = 'Standard_E16ds_v4'
var vmSize string = 'Standard_E20ds_v5'

@description('VMSS name')
var vmssName string = 'ingest-vmss'

@description('Azure user name')
var adminUsername string = 'azureuser'

@description('Trigger schedule in cron format, e.g. "0 0 10 * * 1" for every Monday at 10:00 GMT')
var triggerSchedule string = '0 0 10 * * 1'

// Get existing resources
resource vnet 'Microsoft.Network/virtualNetworks@2022-09-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2022-09-01' existing = {
  parent: vnet
  name: vmSubnetName
}

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: '${prefix}-uami'
}

// Get LA workspace
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: logAnalyticsWorkspaceName
}

// Application Insights
resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

// Tilesrv Container App
resource tilesrvApp 'Microsoft.App/containerapps@2025-02-02-preview' existing = {
  name: tilesrvAppName
}

resource dbService 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' existing = {
  name: dbServiceName
}

// Build cloud init, now we have retrieved the existing resources
// We then interpolate a block of environment variables into the cloud-init file
@description('Cloud init file before substitution')
var cloudInitRaw = loadTextContent('./cloud-init.yaml')

// Build one interpolated block in Bicep; note the extra spacing for the YAML indentation
var envLines = [
  'export POSTGIS_HOST=${dbServiceName}.postgres.database.azure.com'
  'export GEN_REGIONS=${genRegions}'
  'export KEY_VAULT_NAME=${keyVaultName}'
  'export CLIENT_ID=${uami.properties.clientId}'
  'export VMSS_NAME=${vmssName}'
  'export RG=${resourceGroup().name}'
  'export TILESRV_APP_URL=https://${tilesrvApp.properties.configuration.ingress.fqdn}'
  'export STORAGE_ACCOUNT_NAME=${storageName}'
  'export UPLOAD_CONTAINER_NAME=${uploadContainerName}'
  'export DOWNLOAD_CONTAINER_NAME=${downloadContainerName}'
]
var envBlock = join(envLines, '\n      ')

@description('Cloud init file after substitution')
var cloudInitRendered = replace(cloudInitRaw, '{{ENV_BLOCK}}', envBlock)

// Create the new resources
resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2024-03-01' = {
  name: 'ingest-vmss'
  location: resourceGroup().location
  sku: {
    name: vmSize
    capacity: 0
    tier: 'Standard'
  }
  properties: {
    upgradePolicy: {
      mode: 'Manual'
    }
    virtualMachineProfile: {
      storageProfile: {
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadOnly'
          diffDiskSettings: {
            option: 'Local' // Ephemeral OS on NVMe
            placement: 'ResourceDisk' // Needs to be CacheDisk (the default) for v4 SKUs
          }
        }
        imageReference: {
          publisher: 'Canonical'
          offer:     'ubuntu-24_04-lts'
          sku:       'server'
          version:   'latest'
        }
      }
      osProfile: {
        computerNamePrefix: 'ingest'
        adminUsername: adminUsername
        customData: base64(cloudInitRendered)
        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: {
            publicKeys: [
              {
                path: '/home/${adminUsername}/.ssh/authorized_keys'
                keyData: sshPublicKey
              }
            ]
          }
        }
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: 'nic'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: 'ipconfig'
                  properties: {
                    subnet: {
                      id: subnet.id
                    }
                    publicIPAddressConfiguration: {
                      name: 'vmssPip'
                      properties: {
                        idleTimeoutInMinutes: 15
                      }
                    }
                  }
                }
              ]
            }
          }
        ]
      }
      // priority: 'Spot' // xxx reinstate for spot
      // evictionPolicy: 'Delete' // xxx reinstate for spot
    }
    // spotRestorePolicy: {  // xxx reinstate for spot
    //   enabled: true
    //   restoreTimeout: 'PT1H'
    // }
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
}

// Let the UAMI be used to scale the VMSS
resource assignScaleRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(uami.id, vmss.id, 'vmss-scale-role')
  scope: vmss
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b24988ac-6180-42a0-ab88-20f7382dd24c'
    )
    principalId: uami.properties.principalId
  }
}

resource amaExt 'Microsoft.Compute/virtualMachineScaleSets/extensions@2024-07-01' = {
  name: 'AzureMonitorLinuxAgent'
  parent: vmss
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    settings: {
      workspaceId: logAnalytics.properties.customerId
      region: resourceGroup().location
      settingsAuthType: 'ManagedIdentity'
    }
    protectedSettings: {} // Deliberately empty.
  }
}

resource dcrAssoc 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: 'dcrassoc'
  scope: vmss
  properties: {
    dataCollectionRuleId: dcr.id
  }
}

// Here be dragons. The DCR can only be created after the custom table, and a dependsOn is insufficient as
// the table creation is asynchronous. We could script the dependency, but haven't yet.
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'datacollectionrule'
  location: resourceGroup().location
  kind: 'Linux'
  properties: {
    description: 'Collect ingest logs'

    // 1) Define the custom stream and its columns.
    streamDeclarations: {
        'Custom-IngestLogs':{
          columns: [
            {
              name: 'TimeGenerated'
              type: 'datetime'
            }
            {
              name: 'RawData'
              type: 'string'
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

    // 2) Point log files data source at that stream.
    dataSources: {
      logFiles: [
        {
          name: 'jobLogs'
          filePatterns: [
            '/opt/ingest/logs/*.log'
            '/opt/ingest/logs/*.csv'
          ]
          format: 'text'
          settings: {
            text: { recordStartTimestampFormat: 'YYYY-MM-DD HH:MM:SS' }
          }
          streams: ['Custom-IngestLogs']
        }
      ]
    }

    // 3) Send to your workspace.
    destinations: {
      logAnalytics: [
        {
          name: 'workspace'
          workspaceResourceId: logAnalytics.id
        }
      ]
    }

    // 4) Map stream to workspace.
    dataFlows: [
      {
        streams:      ['Custom-IngestLogs']
        destinations: ['workspace']
        outputStream: 'Custom-IngestLogs_CL'
      }
    ]
  }
}

// Azure function that triggers weekly updates
var planName        = '${prefix}-plan'

// 1) Storage Account for FUNCTIONS runtime
resource storage 'Microsoft.Storage/storageAccounts@2022-09-01' existing = {
  name: storageName
}

// Grab the first storage account key
var storageKey = storage.listKeys().keys[0].value

// Blob service and storage in that account for the function app code and uploads
var functionContainerName = 'functionapp'
var uploadContainerName = 'uploads'
var downloadContainerName = 'downloads'

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2022-09-01' existing = {
  name: 'default'
  parent: storage
}

resource functionContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  name: functionContainerName
  parent: blobService
}

resource uploadContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  name: uploadContainerName
  parent: blobService
}

// 1a - UAMI permissions on the storage account
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

resource queueDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, 'queue-contributor', uami.id)
  scope: storage
  properties: {
    principalId: uami.properties.principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor
    )
    principalType: 'ServicePrincipal'
  }
}

// 2) Consumption (Dynamic) plan
resource plan 'Microsoft.Web/serverfarms@2021-02-01' = {
  name: planName
  kind: 'functionapp'
  location: resourceGroup().location
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true // Linux
  }
}

// 3) Function App
resource functionApp 'Microsoft.Web/sites@2024-11-01' = {
  name: functionAppName
  location: resourceGroup().location
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
        maximumInstanceCount: 40 // Seems to be required, and 40 is minimum value
      }
      deployment: {
        storage: {
          // Package location
          type: 'BlobContainer' // Pick most recent blob from this container
          value: 'https://${storageName}.blob.${environment().suffixes.storage}/${functionContainerName}'

          // Auth model for the package fetch (UAMI)
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: uami.id
            // storageAccountConnectionStringName not required when using UAMI
          }
        }
      }
    }
    siteConfig: {
      cors: {
        allowedOrigins: [
          'https://portal.azure.com'    // allow portal XHR calls, required for testing
        ]
      }
      appSettings: [
        //{ name: 'AzureWebJobsStorage__accountName', value: storageName }
        //{ name: 'AzureWebJobsStorage__credential',  value: 'managedidentity' }
        //{ name: 'AzureWebJobsStorage__clientId',    value: uami.properties.clientId }
        //{ name: 'AzureWebJobsStorage__blobServiceUri',  value: 'https://${storageName}.blob.${environment().suffixes.storage}' }
        //{ name: 'AzureWebJobsStorage__queueServiceUri', value: 'https://${storageName}.queue.${environment().suffixes.storage}' }

        { name:  'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storageName};AccountKey=${storageKey};EndpointSuffix=${environment().suffixes.storage}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION',      value: '~4' }
        //{ name: 'SCM_DO_BUILD_DURING_DEPLOYMENT',   value: 'true' }
        //{ name: 'WEBSITE_RUN_FROM_PACKAGE',         value: 'https://${storageName}.blob.${environment().suffixes.storage}/${containerName}/${blobName}' }

        // Diags settings
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING',  value: appInsights.properties.ConnectionString }
        { name: 'APPINSIGHTS_INSTRUMENTATIONKEY',   value: appInsights.properties.InstrumentationKey }
        { name: 'APPLICATIONINSIGHTS_ROLE_NAME',    value: functionAppName }
        // Variables passed to the code
        { name: 'UAMI_CLIENT_ID',                   value: uami.properties.clientId }
        { name: 'AZURE_SUBSCRIPTION_ID',            value: subscription().subscriptionId }
        { name: 'VMSS_RESOURCE_GROUP',              value: resourceGroup().name }
        { name: 'VMSS_NAME',                        value: vmssName }
        { name: 'VMSS_RESOURCE_ID',                 value: vmss.id }
        { name: 'TRIGGER_SCHEDULE',                 value: triggerSchedule }
      ]
    }
  }
}

// Optional: Diagnostic settings from Function App to Log Analytics (platform logs/metrics)
resource funcDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${prefix}-func-diag'
  scope: functionApp
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'FunctionAppLogs'
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

// Dashboard with some plausible metrics
resource dashboard 'Microsoft.Portal/dashboards@2022-12-01-preview' = {
  location: resourceGroup().location
  name: resourceGroup().name
  properties: {
    lenses: [
      {
        order: 0
        parts: [
          {
            position: {
              x: 0
              y: 0
              colSpan: 6
              rowSpan: 4
            }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              settings: {
                content: {
                  options: {
                    chart: {
                      metrics: [
                        {
                          resourceMetadata: {
                            id: appInsights.id
                          }
                          name: 'requests/count'
                          aggregationType: 7
                          namespace: 'microsoft.insights/components'
                          metricVisualization: {
                            displayName: 'Server requests'
                            resourceDisplayName: tilesrvAppName
                          }
                        }
                        {
                          resourceMetadata: {
                            id: appInsights.id
                          }
                          name: 'requests/failed'
                          aggregationType: 7
                          namespace: 'microsoft.insights/components'
                          metricVisualization: {
                            displayName: 'Failed requests'
                            resourceDisplayName: tilesrvAppName
                          }
                        }
                      ]
                      title: 'Tile server requests and failures'
                      titleKind: 1
                      visualization: {
                        chartType: 2
                        legendVisualization: {
                          isVisible: true
                          position: 2
                          hideHoverCard: false
                          hideLabelNames: true
                        }
                        axisVisualization: {
                          x: {
                            isVisible: true
                            axisType: 2
                          }
                          y: {
                            isVisible: true
                            axisType: 1
                          }
                        }
                        disablePinning: false
                      }
                    }
                  }
                }
              }
            }
          }
          {
            position: {
              x: 6
              y: 0
              colSpan: 6
              rowSpan: 4
            }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              settings: {
                content: {
                  options: {
                    chart: {
                      metrics: [
                        {
                          resourceMetadata: {
                            id: tilesrvApp.id
                          }
                          name: 'CpuPercentage'
                          aggregationType: 4
                          namespace: 'microsoft.app/containerapps'
                          metricVisualization: {
                            displayName: 'CPU Usage Percentage (Preview)'
                            resourceDisplayName: tilesrvAppName
                          }
                        }
                        {
                          resourceMetadata: {
                            id: tilesrvApp.id
                          }
                          name: 'MemoryPercentage'
                          aggregationType: 4
                          namespace: 'microsoft.app/containerapps'
                          metricVisualization: {
                            displayName: 'Memory Percentage (Preview)'
                            resourceDisplayName: tilesrvAppName
                          }
                        }
                      ]
                      title: 'Tile server CPU and memory'
                      titleKind: 1
                      visualization: {
                        chartType: 2
                        legendVisualization: {
                          isVisible: true
                          position: 2
                          hideHoverCard: false
                          hideLabelNames: true
                        }
                        axisVisualization: {
                          x: {
                            isVisible: true
                            axisType: 2
                          }
                          y: {
                            isVisible: true
                            axisType: 1
                          }
                        }
                        disablePinning: false
                      }
                    }
                  }
                }
              }
            }
          }
          {
            position: {
              x: 12
              y: 0
              colSpan: 6
              rowSpan: 4
            }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              settings: {
                content: {
                  options: {
                    chart: {
                      metrics: [
                        {
                          resourceMetadata: {
                            id: functionApp.id
                          }
                          name: 'OnDemandFunctionExecutionCount'
                          aggregationType: 1
                          namespace: 'microsoft.web/sites'
                          metricVisualization: {
                            displayName: 'On Demand Function Execution Count'
                            resourceDisplayName: functionAppName
                          }
                        }
                        {
                          resourceMetadata: {
                            id: tilesrvApp.id
                          }
                          name: 'Replicas'
                          aggregationType: 3
                          namespace: 'microsoft.app/containerapps'
                          metricVisualization: {
                            displayName: 'Replica Count'
                            resourceDisplayName: tilesrvAppName
                          }
                        }
                      ]
                      title: 'Count of tilesrv replicas and ingestion triggers'
                      titleKind: 1
                      visualization: {
                        chartType: 2
                        legendVisualization: {
                          isVisible: true
                          position: 2
                          hideHoverCard: false
                          hideLabelNames: true
                        }
                        axisVisualization: {
                          x: {
                            isVisible: true
                            axisType: 2
                          }
                          y: {
                            isVisible: true
                            axisType: 1
                          }
                        }
                        disablePinning: false
                      }
                    }
                  }
                }
              }
            }
          }
          {
            position: {
              x: 0
              y: 8
              colSpan: 6
              rowSpan: 4
            }
           metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              settings: {
                content: {
                  options: {
                    chart: {
                      metrics: [
                        {
                          resourceMetadata: {
                            id: dbService.id
                          }
                          name: 'cpu_percent'
                          aggregationType: 4
                          namespace: 'microsoft.dbforpostgresql/flexibleservers'
                          metricVisualization: {
                            displayName: 'CPU percent'
                          }
                        }
                        {
                          resourceMetadata: {
                            id: dbService.id
                          }
                          name: 'memory_percent'
                          aggregationType: 4
                          namespace: 'microsoft.dbforpostgresql/flexibleservers'
                          metricVisualization: {
                            displayName: 'Memory percent'
                          }
                        }
                      ]
                      title: 'Database CPU and memory'
                      titleKind: 1
                      visualization: {
                        chartType: 2
                        legendVisualization: {
                          isVisible: true
                          position: 2
                          hideHoverCard: false
                          hideLabelNames: true
                        }
                        axisVisualization: {
                          x: {
                            isVisible: true
                            axisType: 2
                          }
                          y: {
                            isVisible: true
                            axisType: 1
                          }
                        }
                        disablePinning: false
                      }
                    }
                  }
                }
              }
            }
          }
          {
            position: {
              x: 6
              y: 8
              colSpan: 6
              rowSpan: 4
            }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              settings: {
                content: {
                  options: {
                    chart: {
                      metrics: [
                        {
                          resourceMetadata: {
                            id: dbService.id
                          }
                          name: 'storage_used'
                          aggregationType: 4
                          namespace: 'microsoft.dbforpostgresql/flexibleservers'
                          metricVisualization: {
                            displayName: 'Storage used'
                            resourceDisplayName: dbServiceName
                          }
                        }
                      ]
                      title: 'Database storage use'
                      titleKind: 1
                      visualization: {
                        chartType: 2
                        legendVisualization: {
                          isVisible: true
                          position: 2
                          hideHoverCard: false
                          hideLabelNames: true
                        }
                        axisVisualization: {
                          x: {
                            isVisible: true
                            axisType: 2
                          }
                          y: {
                            isVisible: true
                            axisType: 1
                          }
                        }
                        disablePinning: false
                      }
                    }
                  }
                }
              }
            }
          }
          {
            position: {
              x: 0
              y: 4
              colSpan: 6
              rowSpan: 4
            }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              settings: {
                content: {
                  options: {
                    chart: {
                      metrics: [
                        {
                          resourceMetadata: {
                            id: '/subscriptions/b9ba9683-feef-47c8-bcc0-08e791dc1493/resourceGroups/rg-ssp-shared-dev-uks/providers/Microsoft.Cdn/profiles/fpd-ssp-prd2-uks-01' // Hard coded - only one Front Door
                          }
                          name: 'RequestCount'
                          aggregationType: 1
                          namespace: 'microsoft.cdn/profiles'
                          metricVisualization: {
                            displayName: 'Total Request Count'
                          }
                        }
                        {
                          resourceMetadata: {
                            id: '/subscriptions/b9ba9683-feef-47c8-bcc0-08e791dc1493/resourceGroups/rg-ssp-shared-dev-uks/providers/Microsoft.Cdn/profiles/fpd-ssp-prd2-uks-01' // Hard coded - only one Front Door
                          }
                          name: 'OriginRequestCount'
                          aggregationType: 1
                          namespace: 'microsoft.cdn/profiles'
                          metricVisualization: {
                            displayName: 'Origin Request Count'
                          }
                        }
                      ]
                      title: 'Total and Origin request counts for Front Door'
                      titleKind: 1
                      visualization: {
                        chartType: 2
                        legendVisualization: {
                          isVisible: true
                          position: 2
                          hideHoverCard: false
                          hideLabelNames: true
                        }
                        axisVisualization: {
                          x: {
                            isVisible: true
                            axisType: 2
                          }
                          y: {
                            isVisible: true
                            axisType: 1
                          }
                        }
                        disablePinning: true
                      }
                    }
                  }
                }
              }
            }
          }
          {
            position: {
              x: 6
              y: 4
              colSpan: 6
              rowSpan: 4
            }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MonitorChartPart'
              settings: {
                content: {
                  options: {
                    chart: {
                      metrics: [
                        {
                          resourceMetadata: {
                            id: '/subscriptions/b9ba9683-feef-47c8-bcc0-08e791dc1493/resourceGroups/rg-ssp-shared-dev-uks/providers/Microsoft.Cdn/profiles/fpd-ssp-prd2-uks-01' // Hard coded - only one Front Door
                          }
                          name: 'TotalLatency'
                          aggregationType: 4
                          namespace: 'microsoft.cdn/profiles'
                          metricVisualization: {
                            displayName: 'Total Latency'
                          }
                        }
                        {
                          resourceMetadata: {
                            id: '/subscriptions/b9ba9683-feef-47c8-bcc0-08e791dc1493/resourceGroups/rg-ssp-shared-dev-uks/providers/Microsoft.Cdn/profiles/fpd-ssp-prd2-uks-01' // Hard coded - only one Front Door
                          }
                          name: 'OriginLatency'
                          aggregationType: 4
                          namespace: 'microsoft.cdn/profiles'
                          metricVisualization: {
                            displayName: 'Origin Latency'
                          }
                        }
                      ]
                      title: 'Total and Origin Latency averages for Front Door'
                      titleKind: 1
                      visualization: {
                        chartType: 2
                        legendVisualization: {
                          isVisible: true
                          position: 2
                          hideHoverCard: false
                          hideLabelNames: true
                        }
                        axisVisualization: {
                          x: {
                            isVisible: true
                            axisType: 2
                          }
                          y: {
                            isVisible: true
                            axisType: 1
                          }
                        }
                        disablePinning: true
                      }
                    }
                  }
                }
              }
            }
          }
        ]
      }
    ]
  }
}
