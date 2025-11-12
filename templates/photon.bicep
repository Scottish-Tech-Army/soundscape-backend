@description('Prefix for the deployment, e.g. aNN')
param prefix string

@description('Storage account name')
param storageName string

@description('Name and RG of the Azure Container Registry')
param registryName string
param registryRG string

@description('Version tag for the photon-docker image')
param versionTag string

@description('Name of the Azure Container Registry UAMI - pre-existing, and should be supplied as a parameter really')
// FIXME: hardcoded
param registryUAMIName string = 'mi-ssp-dev-uks-acrpull'

@description('Name of the virtual network')
var vnetName string = '${prefix}-vnet'

@description('Address range for the VNet')
var vnetAddressPrefix string = '10.1.0.0/16'

@description('Address range and name for the VM subnet')
var vmSubnetPrefix string = '10.1.16.0/20'
var vmSubnetName string = 'vm-subnet'

@description('Log Analytics workspace name')
var logAnalyticsWorkspaceName string = '${prefix}-law-${uniqueString(resourceGroup().id)}'

@description('Name of the storage container for downloads')
var downloadContainerName = 'downloads'

@description('Name of the storage container for uploads')
var uploadContainerName = 'uploads'

@description('Area to download - normally planet or monaco for local testing')
param area string

// Get the UAMI from the other subscription
resource registryUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: registryUAMIName
  scope: resourceGroup(registryRG)
}

// UAMI for the VMSS
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: '${prefix}-uami'
  location: resourceGroup().location
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
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2022-09-01' = {
  parent: vnet
  name: vmSubnetName
  properties: {
    addressPrefix: vmSubnetPrefix
  }
}

// Log analytics workspace for diagnostics
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2020-08-01' = {
  name: logAnalyticsWorkspaceName
  location: resourceGroup().location
  properties: {}
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

// Create a table for photon logs
resource customTable 'Microsoft.OperationalInsights/workspaces/tables@2025-02-01' = {
  name: 'photonLogs_CL' // "_CL" suffix is required
  parent: logAnalytics
  properties: {
    plan: 'Basic'
    schema: {
      name: 'photonLogs_CL'
      displayName: 'photon Logs'
      description: 'Custom table for photon server logs'
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

resource downloadContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  name: downloadContainerName
  parent: blobService
}

resource uploadContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  name: uploadContainerName
  parent: blobService
}

// From here on, things that never change, so just vars
@description('ssh key')
var sshPublicKey string = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK3Nyaoy93lLUDkZY7V0dh2WdA9E8Zl0R+JLuR8EGwfJ'

@description('VM size supporting ephemeral NVMe OS disk')
var vmSize string = 'Standard_E2ps_v6' // 2 core, 16GB RAM, ARM processor

@description('VMSS name')
var vmssName string = '${prefix}-vmss'

@description('Azure user name')
var adminUsername string = 'azureuser'

// Build cloud init, now we have retrieved the existing resources
// We then interpolate a block of environment variables into the cloud-init file
@description('Cloud init file before substitution')
var cloudInitRaw = loadTextContent('./photon-cloud-init.yaml')

// Build one interpolated block in Bicep; note the extra spacing for the YAML indentation
var envLines = [
  'export CLIENT_ID=${uami.properties.clientId}'
  'export ACR_CLIENT_ID=${registryUami.properties.clientId}'
  'export REGISTRY_NAME=${registryName}'
  'export IMAGE=${registryName}.azurecr.io/photon-docker:${versionTag}'
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

// Create the new resources
resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2024-03-01' = {
  name: vmssName
  location: resourceGroup().location
  sku: {
    name: vmSize
    capacity: 1
    tier: 'Standard'
  }
  properties: {
    upgradePolicy: {
      mode: 'Rolling'
      rollingUpgradePolicy: {
        maxSurge: true
      }
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
        computerNamePrefix: 'pmtiles'
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
      priority: 'Regular'
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
    description: 'Collect pmtiles logs'

    // 1) Define the custom stream and its columns.
    streamDeclarations: {
        'Custom-pmtilesLogs':{
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
            '/opt/pmtiles/logs/*.log'
            '/opt/pmtiles/logs/*.csv'
          ]
          format: 'text'
          settings: {
            //text: { recordStartTimestampFormat: 'YYYY-MM-DD HH:MM:SS' }
            text: { recordStartTimestampFormat: 'ISO 8601' }
          }
          streams: ['Custom-pmtilesLogs']
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
        streams: ['Custom-pmtilesLogs']
        destinations: ['workspace']
        outputStream: 'Custom-pmtilesLogs_CL'
      }
      {
        streams: ['Microsoft-Perf']
        destinations: ['workspace']
      }
    ]
  }
}

