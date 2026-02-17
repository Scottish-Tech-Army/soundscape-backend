@description('Prefix for the deployment, e.g. aNN')
param prefix string

@description('Metric function app name')
param metricAppName string

@description('Trigger function app name')
param triggerAppName string

@description('Storage account name')
param storageName string

@description('VM scale')
param scale int = 1

@description('Name and RG of the Azure Container Registry')
param registryName string
param registryRG string
param registryUAMIName string

@description('Version tag for the photon-docker image')
param versionTag string

@description('Shared RG name')
param sharedRGName string

//@description('Shared Log Analytics workspace name')
param sharedLAW string

@description('Front Door name')
param frontDoorName string

@description('Is this a debug deployment - ssh access enabled')
param debug bool = false

@description('Subscription ID')
var subId = subscription().subscriptionId

// From here on, things that never change, so just vars
@description('ssh key')
var sshPublicKey string = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK3Nyaoy93lLUDkZY7V0dh2WdA9E8Zl0R+JLuR8EGwfJ'

@description('VM size supporting ephemeral NVMe OS disk')
var vmSize string = 'Standard_E2ps_v6' // 2 core, 16GB RAM, ARM processor

// By default, the VM ends up with just 2GB of RAM, so we beef it up a bit
@description('Java arguments')
var javaArgs string = '-Xmx8G -Xms8G -XX:+UseG1GC'

@description('VMSS name')
var vmssName string = '${prefix}-vmss'

@description('Azure user name')
var adminUsername string = 'azureuser'

@description('Name of the virtual network')
var vnetName string = '${prefix}-vnet'

@description('Address range for the VNet')
var vnetAddressPrefix string = '10.1.0.0/16'

@description('Address range and name for the VM subnet')
var vmSubnetPrefix string = '10.1.16.0/20'
var vmSubnetName string = 'vm-subnet'
var nsgName string = 'vm-nsg'

@description('Log Analytics workspace name')
var logAnalyticsWorkspaceName string = '${prefix}-law-${uniqueString(resourceGroup().id)}'

@description('Name of the storage container for downloads')
var downloadContainerName = 'downloads'

@description('Name of the storage container for uploads')
var uploadContainerName = 'uploads'

@description('Area to download - normally planet or monaco for local testing')
param area string

@description('Diags RG with alert group')
param diagsRG string

@description('Trigger schedule in cron format, e.g. "0 0 10 * * 1" for every Monday at 10:00 GMT')
// Format: seconds / minutes / hours / day of month / month / day of week (0=Sun)
// https://learn.microsoft.com/en-gb/azure/azure-functions/functions-bindings-timer?tabs=python-v2%2Cisolated-process%2Cnodejs-v4&utm_source=copilot.com&pivots=programming-language-csharp#ncrontab-expressions
// This is 12 noon on the 1st of every month
var triggerSchedule string = '0 0 12 1 * *' // 12:00 GMT on the 1st of every month

// Get the UAMI from the other subscription
resource registryUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: registryUAMIName
  scope: resourceGroup(registryRG)
}

// UAMI for the VMSS
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: '${prefix}-uami'
}

// NSG
resource nsg 'Microsoft.Network/networkSecurityGroups@2022-09-01' = {
  name: nsgName
  location: resourceGroup().location
  properties: {
    securityRules: [
      {
        name: 'Allow-FrontDoor-2322'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '2322'
          sourceAddressPrefix: 'AzureFrontDoor.Backend'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-AzureLoadBalancer'
        properties: {
          priority: 300
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'Allow-VirtualNetwork'
        properties: {
          priority: 400
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
        }
      }
      ...(debug ? [
        {
          name: 'Allow-SSH'
          properties: {
            priority: 500
            direction: 'Inbound'
            access: 'Allow'
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '22'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: '*'
          }
        }
      ] : [])
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 600
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// vnet
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: resourceGroup().location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: vmSubnetName
  properties: {
    addressPrefix: vmSubnetPrefix
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

// Log analytics workspace
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2020-08-01' existing = {
  name: logAnalyticsWorkspaceName
}

// Get shared LA workspace
resource sharedLogAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: sharedLAW
  scope: resourceGroup(sharedRGName)
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

// Build cloud init, now we have retrieved the existing resources
// We then interpolate a block of environment variables into the cloud-init file
@description('Cloud init file before substitution')
var cloudInitRaw = loadTextContent('./photon-cloud-init.yaml')

// Build one interpolated block in Bicep; note the extra spacing for the YAML indentation
var envLines = [
  'export CLIENT_ID=${uami.properties.clientId}'
  'export ACR_CLIENT_ID=${registryUami.properties.clientId}'
  'export REGISTRY_NAME=${registryName}'
  'export PHOTONIMAGE=${registryName}.azurecr.io/photon/photon-docker:${versionTag}'
  'export VMSS_NAME=${vmssName}'
  'export RG=${resourceGroup().name}'
  'export STORAGE_ACCOUNT_NAME=${storageName}'
  'export UPLOAD_CONTAINER_NAME=${uploadContainerName}'
  'export DOWNLOAD_CONTAINER_NAME=${downloadContainerName}'
  'export AREA=${area}'
  'export JAVA_ARGS="${javaArgs}"'
]
var envBlock = join(envLines, '\n      ')

@description('Cloud init file after substitution')
var cloudInitRendered = replace(cloudInitRaw, '{{ENV_BLOCK}}', envBlock)

// Create the new resources - LB and public IP first
var lbName string = '${prefix}-lb'
var lbFrontEndName string = 'photon-fe'
var lbBackendPoolName string = 'photon-pool'
var lbProbeName string = 'photon-probe'
var dnsLabel = 'photon-${uniqueString(resourceGroup().id)}'
var publicIpName string = '${prefix}-publicip'

resource publicIp 'Microsoft.Network/publicIPAddresses@2022-09-01' = {
  name: publicIpName
  location: resourceGroup().location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: dnsLabel
    }
  }
}

resource lb 'Microsoft.Network/loadBalancers@2024-10-01' = {
  name: lbName
  location: resourceGroup().location
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: lbFrontEndName
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: lbBackendPoolName
      }
    ]
    loadBalancingRules: [
      {
        name: 'photon-rule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, lbFrontEndName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, lbBackendPoolName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, lbProbeName)
          }
          protocol: 'Tcp'
          frontendPort: 2322
          backendPort: 2322
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
          loadDistribution: 'Default'
        }
      }
/*
      {
        name: 'health-probe-rule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, lbFrontEndName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, lbBackendPoolName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, lbProbeName)
          }
          protocol: 'Tcp'
          frontendPort: 2320
          backendPort: 2320
          disableOutboundSnat: true
        }
      }
*/
    ]
    probes: [
      {
        name: lbProbeName
        properties: {
          // Http probes turn out to be buggy, so we use a simple TCP probe and a health container
          protocol: 'Tcp'
          port: 2320
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
  }
}

// VMSS that runs photon server
resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2025-04-01' = {
  name: vmssName
  location: resourceGroup().location
  sku: {
    name: vmSize
    capacity: scale
    tier: 'Standard'
  }
  properties: {
    upgradePolicy: {
      mode: 'Manual'
    }
    overprovision: false
    // It would be nice to have automaticRepairsPolicy set, but they have a max grace period of 90 minutes, which is less than our startup time.
    virtualMachineProfile: {
      storageProfile: {
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadOnly'
          managedDisk: {
            storageAccountType: 'Standard_LRS'
          }
          diskSizeGB: 32
        }
        imageReference: {
          publisher: 'Canonical'
          offer:     'ubuntu-24_04-lts'
          sku:       'server-arm64'
          version:   'latest'
        }
        diskControllerType: 'SCSI'

        // Added data disk
        dataDisks: [
          {
            lun: 0
            createOption: 'Empty'
            diskSizeGB: 256
            caching: 'ReadOnly'
            managedDisk: {
              storageAccountType: 'Standard_LRS'
            }
          }
        ]
      }
      osProfile: {
        computerNamePrefix: 'photon'
        adminUsername: adminUsername
        customData: base64(cloudInitRendered)
        linuxConfiguration: {
          disablePasswordAuthentication: true
            // We have to put an ssh key here; VMs must have either a key or a password.
            // Thus do not remove if debug is set.
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
      extensionProfile: {
        extensions: [
          {
            name: 'AzureMonitorLinuxAgent'
            properties: {
              publisher: 'Microsoft.Azure.Monitor'
              type: 'AzureMonitorLinuxAgent'
              typeHandlerVersion: '1.0'
              autoUpgradeMinorVersion: true
              settings: {
                workspaceId: logAnalytics.properties.customerId
                region: resourceGroup().location
                settingsAuthType: 'ManagedIdentity'
                authentication: {
                  managedIdentity: {
                    'identifier-name': 'mi_res_id'
                    'identifier-value': uami.id
                  }
                }
              }
              protectedSettings: {} // Deliberately empty.
            }
          }
          {
            name: 'noop-reimage-trigger'
            properties: {
              publisher: 'Microsoft.Azure.Extensions'
              type: 'CustomScript'
              typeHandlerVersion: '2.0'
              autoUpgradeMinorVersion: true
              settings: {
                commandToExecute: '/bin/true'
              } // nothing to run
              protectedSettings: {} // nothing secret
              forceUpdateTag: 'initial'
            }
          }
          {
            name: 'HealthExtension'
            properties: {
              publisher: 'Microsoft.ManagedServices'
              type: 'ApplicationHealthLinux'
              typeHandlerVersion: '2.0'
              autoUpgradeMinorVersion: true
              settings: {
                protocol: 'tcp'
                port: 2320 // Health port, not load port
                intervalInSeconds: 10
                numberOfProbes: 3
                gracePeriod: 600 // 10 minutes before we allow the option of it being healthy
              }
            }
          }
        ]
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
                    ...(debug ? {
                      publicIPAddressConfiguration: {
                        name: 'vmssPip'
                        properties: {
                          idleTimeoutInMinutes: 15
                        }
                      }
                    } : {})
                    loadBalancerBackendAddressPools: [{
                      id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, lbBackendPoolName)
                    }]
                  }
                }
              ]
            }
          }
        ]
      }
      priority: 'Regular'
    }
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
      '${registryUami.id}': {}
    }
  }
}

// Let the UAMI be used to scale the VMSS
resource assignScaleRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(uami.id, vmss.id, 'vmss-update-role')
  scope: vmss
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b24988ac-6180-42a0-ab88-20f7382dd24c' // Contributor
    )
    principalId: uami.properties.principalId
  }
}

// The UAMI also needs to be able to assign itself to the VMSS, because this is a rePUT of the entire VMSS
resource assignUamiOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(uami.id, 'uami-operator')
  scope: uami
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'f1a07417-d97a-45cb-824c-7a7467783830' // Managed Identity Operator
    )
    principalId: uami.properties.principalId
  }
}

// ... and it needs to be allowed to link the VMSS to the network and the load balancer
resource networkContributorOnRg 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(uami.id, 'network-contributor-rg')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4d97b98b-1d4f-4787-a291-c67834d212e7' // Network Contributor
    )
    principalId: uami.properties.principalId
  }
}

resource dcrAssoc 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: 'dcrassoc'
  scope: vmss
  properties: {
    dataCollectionRuleId: dcr.id
  }
}

// Note that the DCR can only be created after the custom table, created in the earlier bicep script.
resource dcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: 'datacollectionrule'
  location: resourceGroup().location
  kind: 'Linux'
  properties: {
    description: 'Collect photon logs'

    // 1) Define the custom stream and its columns.
    streamDeclarations: {
        'Custom-photonLogs':{
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
            '/opt/photon/logs/*.log'
            '/opt/photon/logs/*.csv'
          ]
          format: 'text'
          settings: {
            //text: { recordStartTimestampFormat: 'YYYY-MM-DD HH:MM:SS' }
            text: { recordStartTimestampFormat: 'ISO 8601' }
          }
          streams: ['Custom-photonLogs']
        }
      ]

      performanceCounters: [
        {
          name: 'linuxPerfCounters'
          streams: ['Microsoft-Perf']
          samplingFrequencyInSeconds: 60
          // In theory, you get all counters if you provide '*' here, but it does not seem to work.
          counterSpecifiers: [
            'Processor(*)\\% Processor Time'
            'Processor(*)\\% Idle Time'
            'Processor(*)\\% User Time'
            'Processor(*)\\% Nice Time'
            'Processor(*)\\% Privileged Time'
            'Processor(*)\\% IO Wait Time'
            'Processor(*)\\% Interrupt Time'
            'Memory(*)\\Available MBytes Memory'
            'Memory(*)\\% Available Memory'
            'Memory(*)\\Used Memory MBytes'
            'Memory(*)\\% Used Memory'
            'Memory(*)\\Pages/sec'
            'Memory(*)\\Page Reads/sec'
            'Memory(*)\\Page Writes/sec'
            'Memory(*)\\Available MBytes Swap'
            'Memory(*)\\% Available Swap Space'
            'Memory(*)\\Used MBytes Swap Space'
            'Memory(*)\\% Used Swap Space'
            'Process(*)\\Pct User Time'
            'Process(*)\\Pct Privileged Time'
            'Process(*)\\Used Memory'
            'Process(*)\\Virtual Shared Memory'
            'Logical Disk(*)\\% Free Inodes'
            'Logical Disk(*)\\% Used Inodes'
            'Logical Disk(*)\\Free Megabytes'
            'Logical Disk(*)\\% Free Space'
            'Logical Disk(*)\\% Used Space'
            'Logical Disk(*)\\Logical Disk Bytes/sec'
            'Logical Disk(*)\\Disk Read Bytes/sec'
            'Logical Disk(*)\\Disk Write Bytes/sec'
            'Logical Disk(*)\\Disk Transfers/sec'
            'Logical Disk(*)\\Disk Reads/sec'
            'Logical Disk(*)\\Disk Writes/sec'
            'Network(*)\\Total Bytes Transmitted'
            'Network(*)\\Total Bytes Received'
            'Network(*)\\Total Bytes'
            'Network(*)\\Total Packets Transmitted'
            'Network(*)\\Total Packets Received'
            'Network(*)\\Total Rx Errors'
            'Network(*)\\Total Tx Errors'
            'Network(*)\\Total Collisions'
            'System(*)\\Uptime'
            'System(*)\\Load1'
            'System(*)\\Load5'
            'System(*)\\Load15'
            'System(*)\\Users'
            'System(*)\\Unique Users'
            'System(*)\\CPUs'
          ]
        }
      ]
    }

    // 3) Send to the workspace.
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
        streams: ['Custom-photonLogs']
        destinations: ['workspace']
        outputStream: 'Custom-photonLogs_CL'
      }
      {
        streams: ['Microsoft-Perf']
        destinations: ['workspace']
      }
    ]
  }
}

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
    triggerType: 'REIMAGE'
  }
}

var vmKqlQuery = loadTextContent('../build/vmquery-escaped.txt')
var errorKqlQuery = loadTextContent('../build/error-escaped.txt')
var requestKqlQuery = loadTextContent('../build/request-escaped.txt')

// Workbook for VMSS metrics
module vmWorkbook './workbook.bicep' = {
  name: 'vmWorkbook'
  params: {
    kqlQuery: vmKqlQuery
    title: 'VM Instance Counts'
    ySettings: '{"min": 0}' // Do not let the Y axis scale only to 1
    logAnalyticsId: logAnalytics.id
    workbookDisplayName: '${prefix}-vmss-counter'
  }
}

// Workbook for FrontDoor errors
module errorWorkbook './workbook.bicep' = {
  name: 'errorWorkbook'
  params: {
    kqlQuery: errorKqlQuery
    title: 'Front door errors'
    ySettings: '{"min": 0}' // Do not let the Y axis scale only to 1
    logAnalyticsId: sharedLogAnalytics.id
    workbookDisplayName: '${prefix}-error-counter'
  }
}

// Workbook for FrontDoor requests
module requestWorkbook './workbook.bicep' = {
  name: 'requestWorkbook'
  params: {
    kqlQuery: requestKqlQuery
    title: 'Front door requests'
    ySettings: '{"min": 0}' // Do not let the Y axis scale only to 1
    logAnalyticsId: sharedLogAnalytics.id
    workbookDisplayName: '${prefix}-request-counter'
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
                      title: 'Total and Origin request counts for Front Door (iOS and photon combined)'
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
              y: 0
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
                  value: requestWorkbook.outputs.id
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
                  value: requestWorkbook.outputs.title
                  isOptional: true
                }
                {
                  name: 'StepSettings'
                  // Aggregation 0 is Sum, 1 is Min, 2 is Max, 3 is Avg, 4 is First, 5 is Last
                  value: '{"version":"KqlItem/1.0","query":${requestKqlQuery},"size":0,"aggregation":0,"title":"Front Door requests","timeContextFromParameter":"TimeRange","queryType":0,"resourceType":"microsoft.operationalinsights/workspaces","crossComponentResources":["${sharedLogAnalytics.id}"],"visualization":"linechart","gridSettings":{"sortBy":[{"itemKey":"TimeGenerated","sortOrder":1}]},"sortBy":[{"itemKey":"TimeGenerated","sortOrder":1}],"chartSettings":{"xAxis":"TimeGenerated"}}'
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
              y: 0
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
                            id: lb.id
                          }
                          name: 'ByteCount'
                          aggregationType: 1
                          namespace: 'microsoft.network/loadbalancers'
                          metricVisualization: {
                            displayName: 'Byte Count'
                            resourceDisplayName: lbName
                          }
                        }
                      ]
                      title: 'Total byte traffic on photon load balancer'
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
                            id: vmss.id
                          }
                          name: 'Available Memory Percentage'
                          aggregationType: 4
                          namespace: 'microsoft.compute/virtualmachinescalesets'
                          metricVisualization: {
                            displayName: 'Available Memory Percentage'
                            resourceDisplayName: vmssName
                          }
                        }
                        {
                          resourceMetadata: {
                            id: vmss.id
                          }
                          name: 'Percentage CPU'
                          aggregationType: 4
                          namespace: 'microsoft.compute/virtualmachinescalesets'
                          metricVisualization: {
                            displayName: 'Percentage CPU used'
                            resourceDisplayName: vmssName
                          }
                        }
                      ]
                      title: 'VMSS available memory and used CPU'
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
              y: 4
              colSpan: 6
              rowSpan: 4
            }
            metadata: {
              inputs: []
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              settings: {
                content: {
                  title: 'Legacy URL traffic'
                  content: '''
When we support the legacy URL, we should ensure that we have a graph. We will add this in due course.
'''
                  markdownSource: 1
                  markdownUri: ''
                }
              }
            }
          }
          {
            position: {
              x: 0
              y: 8
              colSpan: 8
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
                  value: '{"version":"KqlItem/1.0","query":${vmKqlQuery},"size":0,"aggregation":2,"title":"VM instances","timeContextFromParameter":"TimeRange","queryType":0,"resourceType":"microsoft.operationalinsights/workspaces","crossComponentResources":["${logAnalytics.id}"],"visualization":"linechart","gridSettings":{"sortBy":[{"itemKey":"TimeGenerated","sortOrder":1}]},"sortBy":[{"itemKey":"TimeGenerated","sortOrder":1}],"chartSettings":{"xAxis":"TimeGenerated","ySettings":{"min": 0}}}'
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
              inputs: []
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              settings: {
                content: {
                  title: 'Placeholder'
                  content: '''
This is a documentation placeholder.
'''
                  markdownSource: 1
                  markdownUri: ''
                }
              }
            }
          }
        ]
      }
    ]
  }
}

// Last but not least, some alerts
// Alert for fewer than one VM being healthy in the past hour.
module vmUnhealthyAlert './alert.bicep' = {
  name: 'vm-unhealthy-alert'
  params: {
    alertRuleName: 'vm-unhealthy-alert'
    diagsRG: diagsRG
    logAnalyticsId: logAnalytics.id
    displayName: 'Photon VM is unhealthy'
    alertDescription: 'Photon VM in RG ${resourceGroup().name} has no healthy intances'
    windowSize: 'PT24H'
    severity: 1
    alertQuery: '''
      AppTraces
      | where Message contains "METRIC:" and Message contains "Healthy instance count"
      | extend Value = toint(extract(@"METRIC: [\\w ]+: (\\d+)", 1, Message))
      | where TimeGenerated > ago(1h)
      | summarize MinValue = min(Value)
      | where MinValue < 1
    '''
  }
}

// Alert for more than one VM running for more than 12 hours (i.e. failure to scale down after update)
module vmMultipleAlert './alert.bicep' = {
  name: 'vm-multiple-alert'
  params: {
    alertRuleName: 'vm-multiple-alert'
    diagsRG: diagsRG
    logAnalyticsId: logAnalytics.id
    displayName: 'Photon VM did not scale down after reimage'
    alertDescription: 'Photon VM in RG ${resourceGroup().name} failed to cleanly scale down after reimage'
    windowSize: 'PT24H'
    severity: 1
    alertQuery: '''
      AppTraces
      | where Message contains "METRIC:" and Message contains "Current VMSS capacity"
      | extend Value = toint(extract(@"METRIC: [\\w ]+: (\\d+)", 1, Message))
      | where TimeGenerated > ago(12h)
      | summarize MinValue = min(Value)
      | where MinValue > 1
    '''
  }
}

// Alert for more than one VM running briefly (i.e. reimage has started)
module vmRoutineReimage './alert.bicep' = {
  name: 'vm-reimage-alert'
  params: {
    alertRuleName: 'vm-reimage-alert'
    diagsRG: diagsRG
    logAnalyticsId: logAnalytics.id
    displayName: 'Photon VM reimage is occurring'
    alertDescription: 'Photon VM for RG ${resourceGroup().name} has started a normal reimage'
    windowSize: 'PT24H'
    severity: 4
    alertQuery: '''
      AppTraces
      | where Message contains "METRIC:" and Message contains "Current VMSS capacity"
      | extend Value = toint(extract(@"METRIC: [\\w ]+: (\\d+)", 1, Message))
      | where TimeGenerated > ago(1h)
      | summarize MaxValue = max(Value)
      | where MaxValue > 1
    '''
  }
}
