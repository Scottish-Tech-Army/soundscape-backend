// Variables that must be passed in
@description('Prefix for the deployment, e.g. dev, prod, etc.')
param prefix string

@description('Trigger function app name')
param triggerAppName string

@description('Metric function app name')
param metricAppName string

@description('Storage account name')
param storageName string

@description('Tilesrv Container App name')
param tilesrvAppName string

@description('Regions to generate tiles for - planet except for testing. Typical valid values are "planet", "france" and "finland"')
param area string

@description('Diags RG with alert group')
param diagsRG string

@description('Whether to use spot instances for the VMSS - defaults to true')
param useSpot bool = true

@description('Shared RG name')
param sharedRGName string

@description('Shared Log Analytics workspace name')
param sharedLAW string

@description('Front Door name')
param frontDoorName string

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

@description('Trigger schedule in cron format, e.g. "0 0 10 * * 1" for every Monday at 10:00 GMT')
// Format: seconds / minutes / hours / day of month / month / day of week (0=Sun)
// https://learn.microsoft.com/en-gb/azure/azure-functions/functions-bindings-timer?tabs=python-v2%2Cisolated-process%2Cnodejs-v4&utm_source=copilot.com&pivots=programming-language-csharp#ncrontab-expressions
var triggerSchedule string = '0 0 16 15 * *' // 16:00 GMT on the 15th of every month

@description('VM size supporting ephemeral NVMe OS disk')
var vmSize string = 'Standard_E20ds_v6'

@description('VMSS name')
var vmssName string = 'ingest-vmss'

@description('Azure user name')
var adminUsername string = 'azureuser'

@description('Subscription ID')
var subId = subscription().subscriptionId

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

// Get shared LA workspace
resource sharedLogAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: sharedLAW
  scope: resourceGroup(sharedRGName)
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
var cloudInitRaw = loadTextContent('./ios-cloud-init.yaml')

// Build one interpolated block in Bicep; note the extra spacing for the YAML indentation
var envLines = [
  'export POSTGIS_HOST=${dbServiceName}.postgres.database.azure.com'
  'export GEN_REGIONS=${area}'
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
  name: vmssName
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
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
          diskSizeGB: 64
        }
        imageReference: {
          publisher: 'Canonical'
          offer:     'ubuntu-24_04-lts'
          sku:       'server'
          version:   'latest'
        }
        diskControllerType: 'NVMe'
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
      diagnosticsProfile: {
        bootDiagnostics: {
          enabled: true
          storageUri: null // use managed storage
        }
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: 'nic'
            properties: {
              primary: true
              enableAcceleratedNetworking: true
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
      // This wild syntax is a bicep spread operator
      ...(useSpot ? {
        priority: 'Spot'
        evictionPolicy: 'Delete' // If evicted, get rid of disks etc. completely; note that spotRestorePolicy is not set, so VMSS won't try to bring it back automatically
      } : {
            priority: 'Regular'
      })
    }
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

    // 2) Point log files data source at that stream, and add perf counters
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
      performanceCounters: [
        {
          name: 'linuxPerfCounters'
          streams: ['Microsoft-Perf']
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            // CPU
            'Processor(*)\\% Processor Time'
            'Processor(*)\\% User Time'
            'Processor(*)\\% Privileged Time'
            'Processor(*)\\Interrupts/sec'

            // Memory
            'Memory\\Available MBytes'
            'Memory\\Pages/sec'
            'Memory\\Page Faults/sec'
            'Memory\\% Committed Bytes In Use'

            // Disk
            'LogicalDisk(*)\\% Free Space'
            'LogicalDisk(*)\\Disk Transfers/sec'
            'LogicalDisk(*)\\Disk Reads/sec'
            'LogicalDisk(*)\\Disk Writes/sec'
            'LogicalDisk(*)\\Avg. Disk sec/Transfer'
            'LogicalDisk(*)\\Avg. Disk Queue Length'

            // Network
            'Network Interface(*)\\Bytes Total/sec'
            'Network Interface(*)\\Packets/sec'
            'Network Interface(*)\\Bytes Received/sec'
            'Network Interface(*)\\Bytes Sent/sec'
            'Network Interface(*)\\Packets Received/sec'
            'Network Interface(*)\\Packets Sent/sec'
          ]
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
        streams: ['Custom-IngestLogs']
        destinations: ['workspace']
        outputStream: 'Custom-IngestLogs_CL'
      }
      {
        streams: ['Microsoft-Perf']
        destinations: ['workspace']
      }
    ]


  }
}

// Upload and download storage container names
var uploadContainerName = 'uploads'
var downloadContainerName = 'downloads'

module functionApps './functions.bicep' = {
  name: 'functionApps'
  params: {
    prefix: prefix
    triggerAppName: triggerAppName
    metricAppName: metricAppName
    storageName: storageName
    vmssName: vmssName
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    triggerSchedule: triggerSchedule
    triggerType: 'SCALE'
  }
}

var vmKqlQuery = loadTextContent('../build/vmquery-escaped.txt')
var errorKqlQuery = loadTextContent('../build/error-escaped.txt')

// Workbook for VMSS metrics
module vmWorkbook './workbook.bicep' = {
  name: 'vmWorkbook'
  params: {
    kqlQuery: vmKqlQuery
    title: 'VM Instance Counts'
    logAnalyticsId: logAnalytics.id
    workbookDisplayName: '${prefix}-vmss-counter'
  }
}

// Workbook for FrontDoor errors
module errorWorkbook './workbook.bicep' = {
  name: 'errorWorkbook'
  params: {
    kqlQuery: errorKqlQuery
    title: 'VM Instance Counts'
    logAnalyticsId: sharedLogAnalytics.id
    workbookDisplayName: '${prefix}-error-counter'
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
                            id: functionApps.outputs.triggerAppId
                          }
                          name: 'OnDemandFunctionExecutionCount'
                          aggregationType: 1
                          namespace: 'microsoft.web/sites'
                          metricVisualization: {
                            displayName: 'On Demand Function Execution Count'
                            resourceDisplayName: triggerAppName
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
                            id: '/subscriptions/${subId}/resourceGroups/${sharedRGName}/providers/Microsoft.Cdn/profiles/${frontDoorName}'
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
                            id: '/subscriptions/${subId}/resourceGroups/${sharedRGName}/providers/Microsoft.Cdn/profiles/${frontDoorName}'
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
                            id: '/subscriptions/${subId}/resourceGroups/${sharedRGName}/providers/Microsoft.Cdn/profiles/${frontDoorName}'
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
                            id: '/subscriptions/${subId}/resourceGroups/${sharedRGName}/providers/Microsoft.Cdn/profiles/${frontDoorName}'
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
          {
            position: {
              x: 12
              y: 4
              colSpan: 6
              rowSpan: 4
            }
            metadata: {
              inputs: [
                {
                  name: 'ComponentId'
                  value: 'azure monitor'
                  isOptional: true
                }
                {
                  name: 'TimeContext'
                  value: null
                  isOptional: true
                }
                {
                  name: 'ResourceIds'
                  value: [
                    'azure monitor'
                  ]
                  isOptional: true
                }
                {
                  name: 'ConfigurationId'
                  value: errorWorkbook.outputs.id
                  isOptional: true
                }
                {
                  name: 'Type'
                  value: 'workbook'
                  isOptional: true
                }
                {
                  name: 'GalleryResourceType'
                  value: 'azure monitor'
                  isOptional: true
                }
                {
                  name: 'PinName'
                  value: errorWorkbook.outputs.title
                  isOptional: true
                }
                {
                  name: 'StepSettings'
                  // Aggregation 0 is Sum, 1 is Min, 2 is Max, 3 is Avg, 4 is First, 5 is Last
                  value: '{"version":"KqlItem/1.0","query":${errorKqlQuery},"size":0,"aggregation":0,"title":"Error counts","timeContextFromParameter":"TimeRange","queryType":0,"resourceType":"microsoft.operationalinsights/workspaces","crossComponentResources":["${sharedLogAnalytics.id}"],"visualization":"linechart","gridSettings":{"sortBy":[{"itemKey":"TimeGenerated","sortOrder":1}]},"sortBy":[{"itemKey":"TimeGenerated","sortOrder":1}],"chartSettings":{"xAxis":"TimeGenerated"}}'
                  isOptional: true
                }
                {
                  name: 'ParameterValues'
                  value: {
                    TimeRange: {
                      type: 4
                      value: {
                        durationMs: 86400000
                      }
                      isPending: false
                      isWaiting: false
                      isFailed: false
                      isGlobal: false
                      labelValue: 'Last 24 hours'
                      displayName: 'Time range picker'
                      formattedValue: 'Last 24 hours'
                    }
                  }
                  isOptional: true
                }
                {
                  name: 'Location'
                  value: resourceGroup().location
                  isOptional: true
                }
              ]
              type: 'Extension/AppInsightsExtension/PartType/PinnedNotebookQueryPart'
            }
          }
          {
            position: {
              x: 12
              y: 8
              colSpan: 6
              rowSpan: 4
            }
            metadata: {
              inputs: [
                {
                  name: 'ComponentId'
                  value: 'azure monitor'
                  isOptional: true
                }
                {
                  name: 'TimeContext'
                  value: null
                  isOptional: true
                }
                {
                  name: 'ResourceIds'
                  value: [
                    'azure monitor'
                  ]
                  isOptional: true
                }
                {
                  name: 'ConfigurationId'
                  value: vmWorkbook.outputs.id
                  isOptional: true
                }
                {
                  name: 'Type'
                  value: 'workbook'
                  isOptional: true
                }
                {
                  name: 'GalleryResourceType'
                  value: 'azure monitor'
                  isOptional: true
                }
                {
                  name: 'PinName'
                  value: vmWorkbook.outputs.title
                  isOptional: true
                }
                {
                  name: 'StepSettings'
                  value: '{"version":"KqlItem/1.0","query":${vmKqlQuery},"size":0,"aggregation":2,"title":"VM instances","timeContextFromParameter":"TimeRange","queryType":0,"resourceType":"microsoft.operationalinsights/workspaces","crossComponentResources":["${logAnalytics.id}"],"visualization":"linechart","gridSettings":{"sortBy":[{"itemKey":"TimeGenerated","sortOrder":1}]},"sortBy":[{"itemKey":"TimeGenerated","sortOrder":1}],"chartSettings":{"xAxis":"TimeGenerated","ySettings":{"max":1}}}'
                  isOptional: true
                }
                {
                  name: 'ParameterValues'
                  value: {
                    TimeRange: {
                      type: 4
                      value: {
                        durationMs: 86400000
                      }
                      isPending: false
                      isWaiting: false
                      isFailed: false
                      isGlobal: false
                      labelValue: 'Last 24 hours'
                      displayName: 'Time range picker'
                      formattedValue: 'Last 24 hours'
                    }
                  }
                  isOptional: true
                }
                {
                  name: 'Location'
                  value: resourceGroup().location
                  isOptional: true
                }
              ]
              type: 'Extension/AppInsightsExtension/PartType/PinnedNotebookQueryPart'
            }
          }
        ]
      }
    ]
  }
}

// Last but not least, some alerts
// Scheduled query alert rule for detecting "VM ERROR" in LAW logs
module vmErrorAlert './alert.bicep' = {
  name: 'vm-error-alert'
  params: {
    alertRuleName: 'vm-error-alert'
    diagsRG: diagsRG
    logAnalyticsId: logAnalytics.id
    displayName: 'Ingestion VM error'
    alertDescription: 'Ingestion VM for iOS in RG ${resourceGroup().name} reports error'
    severity: 1
    alertQuery: '''
      IngestLogs_CL
      | where FilePath contains "svc"
      | where RawData contains "VM ERROR"
    '''
  }
}

// Scheduled query alert rule for detecting "VM SUCCESS" in LAW logs
module vmSuccessAlert './alert.bicep' = {
  name: 'vm-success-alert'
  params: {
    alertRuleName: 'vm-success-alert'
    diagsRG: diagsRG
    logAnalyticsId: logAnalytics.id
    displayName: 'Ingestion VM success'
    alertDescription: 'Ingestion VM for iOS in RG ${resourceGroup().name} reports successful completion'
    severity: 4
    alertQuery: '''
      IngestLogs_CL
      | where FilePath contains "svc"
      | where RawData contains "VM SUCCESS"
    '''
  }
}

// Scheduled query alert rule for detecting "VM SUCCESS" in LAW logs
module vmTimeoutAlert './alert.bicep' = {
  name: 'vm-timeout-alert'
  params: {
    alertRuleName: 'vm-timeout-alert'
    diagsRG: diagsRG
    logAnalyticsId: logAnalytics.id
    displayName: 'Ingestion VM timed out'
    alertDescription: 'Ingestion VM for iOS in RG ${resourceGroup().name} timed out without completion'
    windowSize: 'PT24H'
    severity: 1
    alertQuery: '''
      AppTraces
      | where Message contains "METRIC:" and Message contains "Current VMSS capacity"
      | extend Value = toint(extract(@"METRIC: [\\w ]+: (\\d+)", 1, Message))
      | where TimeGenerated > ago(12h)
      | summarize MinValue = min(Value)
      | where MinValue > 0
    '''
  }
}
