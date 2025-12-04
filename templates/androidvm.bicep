// Variables that must be passed in
@description('Prefix for the deployment, e.g. dev, prod, etc.')
param prefix string

@description('Trigger function app name')
param triggerAppName string

@description('Metric function app name')
param metricAppName string

@description('Storage account name')
param storageName string

@description('R2 bucket names')
param pmtilesBucket string
param extractsBucket string
var extractsContainerName = extractsBucket // Must match - some scripts assume it

@description('Area to download - normally planet or monaco for local testing')
param area string

// Action group ID for alerts
// FIXME: this could be tidied up, and will be when we move to a shared subscription.
@description('Full ID of action group')
param actionGroupId string = '/subscriptions/4bf1580a-f73d-4821-8cdc-605925ba78e9/resourceGroups/soundscape-diags/providers/Microsoft.Insights/actionGroups/soundscape'

// From here on, things that never change, so just vars
@description('ssh key')
var sshPublicKey string = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK3Nyaoy93lLUDkZY7V0dh2WdA9E8Zl0R+JLuR8EGwfJ'

@description('Name of the virtual network and subnet')
var vnetName string = '${prefix}-vnet'
var vmSubnetName string = 'vm-subnet'

@description('Key vault name')
var keyVaultName string = '${prefix}-vlt-${uniqueString(resourceGroup().id)}'

@description('Log Analytics workspace name')
var logAnalyticsWorkspaceName string = '${prefix}-law-${uniqueString(resourceGroup().id)}'

// Cron format here includes seconds, so is "seconds minutes hours day month day-of-week"
@description('Trigger schedule in cron format, e.g. "0 0 10 * * 1" for every Monday at 10:00 GMT')
var triggerSchedule string = '0 0 12 6 * *' // 12:00 GMT on the 6th of every month

@description('VM size supporting ephemeral NVMe OS disk')
var vmSize string = 'Standard_E20ds_v6' // For spot instances

@description('VMSS name')
var vmssName string = '${prefix}-vmss'

@description('Azure user name')
var adminUsername string = 'azureuser'

@description('Names of containers for upload and download')
var uploadContainerName = 'uploads'
var downloadContainerName = 'downloads'

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

var transferStorageAccountName = 'transfer${uniqueString(resourceGroup().id, resourceGroup().location)}'

// Storage account with internet routing and public access enabled
// This is to allow transfer of files to Cloudflare on demand and without paying
// full egress costs.
resource transferStorage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: transferStorageAccountName
  location: resourceGroup().location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    // Enable public network access to the public endpoint
    publicNetworkAccess: 'Enabled'

    // Allow containers to set public access (required for anonymous blobs)
    allowBlobPublicAccess: true

    // Optional recommended settings
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'

    // Internet routing preference for the public endpoint
    routingPreference: {
      routingChoice: 'InternetRouting'
      publishMicrosoftEndpoints: false
      publishInternetEndpoints: true
    }
  }
}

// Blob service as a parent for containers
resource transferBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  name: 'default'
  parent: transferStorage
  properties: {}
}

// Public container (anonymous read)
resource extractsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: extractsContainerName
  parent: transferBlob
  properties: {
    // Options: 'Blob' (anonymous read of blobs only) or 'Container' (list + read)
    publicAccess: 'Blob'
    metadata: {}
  }
}

// Let the UAMI do as it pleases to that blob
resource blobDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(transferStorage.id, 'blob-contributor', uami.id)
  scope: transferStorage
  properties: {
    principalId: uami.properties.principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor
    )
    principalType: 'ServicePrincipal'
  }
}

// Build cloud init, now we have retrieved the existing resources
// We then interpolate a block of environment variables into the cloud-init file
@description('Cloud init file before substitution')
var cloudInitRaw = loadTextContent('./android-cloud-init.yaml')

// Build one interpolated block in Bicep; note the extra spacing for the YAML indentation
var envLines = [
  'export KEY_VAULT_NAME=${keyVaultName}'
  'export CLIENT_ID=${uami.properties.clientId}'
  'export VMSS_NAME=${vmssName}'
  'export RG=${resourceGroup().name}'
  'export STORAGE_ACCOUNT_NAME=${storageName}'
  'export UPLOAD_CONTAINER_NAME=${uploadContainerName}'
  'export DOWNLOAD_CONTAINER_NAME=${downloadContainerName}'
  'export PMTILES_BUCKET=${pmtilesBucket}'
  'export EXTRACTS_BUCKET=${extractsBucket}'
  'export TRANSFER_STORAGE_ACCOUNT=${transferStorageAccountName}'
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
      priority: 'Spot' // Spot instance to save money
      evictionPolicy: 'Delete' // If evicted, get rid of disks etc. completely; note that spotRestorePolicy is not set, so VMSS won't try to bring it back automatically
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
  }
}

var vmKqlQuery = loadTextContent('../build/vmquery-escaped.txt')

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

// Last but not least, some alerts
// Scheduled query alert rule for detecting "VM ERROR" in LAW logs
module vmErrorAlert './alert.bicep' = {
  name: 'vm-error-alert'
  params: {
    alertRuleName: 'vm-error-alert'
    actionGroupId: actionGroupId
    logAnalyticsId: logAnalytics.id
    displayName: 'Android pmtiles creation VM error'
    alertDescription: 'Android pmtiles VM reports error'
    severity: 1
    alertQuery: '''
      pmtilesLogs_CL
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
    actionGroupId: actionGroupId
    logAnalyticsId: logAnalytics.id
    displayName: 'Android pmtiles VM success'
    alertDescription: 'Android pmtiles VM reports successful completion'
    severity: 4
    alertQuery: '''
      pmtilesLogs_CL
      | where FilePath contains "svc"
      | where RawData contains "VM SUCCESS""
    '''
  }
}

// Scheduled query alert rule for detecting "VM SUCCESS" in LAW logs
module vmTimeoutAlert './alert.bicep' = {
  name: 'vm-timeout-alert'
  params: {
    alertRuleName: 'vm-timeout-alert'
    actionGroupId: actionGroupId
    logAnalyticsId: logAnalytics.id
    displayName: 'Android pmtiles VM timed out'
    alertDescription: 'Android pmtiles VM timed out without completion'
    windowSize: 'PT6H'
    severity: 1
    alertQuery: '''
      AppTraces
      | where Message contains "METRIC:" and Message contains "Current VMSS capacity"
      | extend Value = toint(extract(@"METRIC: [\\w ]+: (\\d+)", 1, Message))
      | summarize MinValue = min(Value)
      | where MinValue > 0
    '''
  }
}
