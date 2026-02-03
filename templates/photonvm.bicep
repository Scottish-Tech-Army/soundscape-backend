@description('Prefix for the deployment, e.g. aNN')
param prefix string

@description('Metric function app name')
param metricAppName string

@description('Trigger function app name')
param triggerAppName string

@description('Storage account name')
param storageName string

@description('VM scale')
param scale int

@description('Name and RG of the Azure Container Registry')
param registryName string
param registryRG string
param registryUAMIName string

@description('Version tag for the photon-docker image')
param versionTag string

// From here on, things that never change, so just vars
@description('ssh key')
var sshPublicKey string = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK3Nyaoy93lLUDkZY7V0dh2WdA9E8Zl0R+JLuR8EGwfJ'

@description('VM size supporting ephemeral NVMe OS disk')
var vmSize string = 'Standard_E2ps_v6' // 2 core, 16GB RAM, ARM processor

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
      {
        // FIXME: disable after testing completes
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

// FIXME: Enable automatic VM repair
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
    ]
    probes: [
      {
        name: lbProbeName
        properties: {
/*
          // Removed because we are now using simple TCP probes
          // Http probes turn out to be buggy
          protocol: 'Http'
          port: 2322
          requestPath: '/status'
*/
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
    overprovision: false // Required with rolling upgrades and maxSurge
    upgradePolicy: {
      mode: 'Rolling'
      rollingUpgradePolicy: {
        maxSurge: true
        // Allow initial rollout even if unhealthy for a while - requires both these to be set
        maxUnhealthyInstancePercent: 100
        maxUnhealthyUpgradedInstancePercent: 100
      }
    }
/*
    // FIXME - grace period cannot be longer than 90 minutes. Unclear how this interfaces with startup time, so maybe need to do something differint.
    automaticRepairsPolicy: {
      enabled: true
      gracePeriod: 'PT12H' // Blow away and replace any VM that has been broken for 12 hours; probably too long, but conservative because of startup time
    }
*/
    virtualMachineProfile: {
      storageProfile: {
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadOnly'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
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
            diskSizeGB: 400
            caching: 'ReadWrite'
            managedDisk: {
              storageAccountType: 'Premium_LRS'
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
/*
          {
            name: 'HealthExtension'
            properties: {
              publisher: 'Microsoft.ManagedServices'
              type: 'ApplicationHealthLinux'
              typeHandlerVersion: '2.0'
              autoUpgradeMinorVersion: true
              settings: {
                protocol: 'tcp'
                port: 2320 // Not the port of the container
                intervalInSeconds: 10
                numberOfProbes: 3
                gracePeriod: 600 // Always takes at least ten minutes
              }
            }
          }
*/
        ]
      }
      networkProfile: {
        // AMA and this kind of probe break one another
        healthProbe: {
          id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, lbProbeName)
        }
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

// Here be dragons. The DCR can only be created after the custom table, and a dependsOn is insufficient as
// the table creation is asynchronous. We could script the dependency, but haven't yet.
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
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

// Workbook for VMSS metrics
module vmWorkbook './workbook.bicep' = {
  name: 'vmWorkbook'
  params: {
    kqlQuery: vmKqlQuery
    title: 'VM Instance Counts'
    ySettings: '{}' // Default ySettings
    logAnalyticsId: logAnalytics.id
    workbookDisplayName: '${prefix}-vmss-counter'
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
              y: 4
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
                  value: '{"version":"KqlItem/1.0","query":${vmKqlQuery},"size":0,"aggregation":2,"title":"VM instances","timeContextFromParameter":"TimeRange","queryType":0,"resourceType":"microsoft.operationalinsights/workspaces","crossComponentResources":["${logAnalytics.id}"],"visualization":"linechart","gridSettings":{"sortBy":[{"itemKey":"TimeGenerated","sortOrder":1}]},"sortBy":[{"itemKey":"TimeGenerated","sortOrder":1}],"chartSettings":{"xAxis":"TimeGenerated","ySettings":{}}}'
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
