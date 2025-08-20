@description('Suffix for the deployment, e.g. dev, prod, etc.')
param suffix string

@description('Name of the virtual network and subnet')
param vnetName string = '${suffix}-vnet'
param vmSubnetName string = 'vm-subnet'

@description('Azure DB for PostgreSQL Flexible Server name')
param dbServiceName string = '${suffix}-database'

@description('Regions to generate tiles for - planet except for testing. Typical valid values are "planet", "france-single" and "france-regions"')
//param genRegions string = 'planet'
//param genRegions string = 'france-regions'
//param genRegions string = 'europe'
param genRegions string = 'noneurope'

@description('Key vault name')
param keyVaultName string = '${suffix}-vlt-${uniqueString(resourceGroup().id)}'

@description('Log Analytics workspace name')
param logAnalyticsWorkspaceName string = '${suffix}-law-${uniqueString(resourceGroup().id)}'

// VM specific parameters
@description('ssh key')
var sshPublicKey string = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK3Nyaoy93lLUDkZY7V0dh2WdA9E8Zl0R+JLuR8EGwfJ plw@plwhite.org'

@description('VM size supporting ephemeral NVMe OS disk')
//param vmSize string = 'Standard_L8s_v3'
//param vmSize string = 'Standard_L8s'
//param vmSize string = 'Standard_E4ds_v4'
param vmSize string = 'Standard_E8ds_v4'

@description('VMSS name')
param vmssName string = 'ingest-vmss'

@description('Azure user name')
param adminUsername string = 'azureuser'

@description('')
param filesTgz string = loadFileAsBase64('../tmp/files.tgz')

// Get existing resources
resource vnet 'Microsoft.Network/virtualNetworks@2022-09-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2022-09-01' existing = {
  parent: vnet
  name: vmSubnetName
}

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: '${suffix}-uami'
}

// Get LA workspace keys
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: logAnalyticsWorkspaceName
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
]
var envBlock = join(envLines, '\n      ')

@description('Cloud init file after substitution')
var cloudInitRendered = replace(replace(cloudInitRaw, '{{ENV_BLOCK}}', envBlock), '{{FILES_TGZ}}', filesTgz)

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
                        //dnsSettings: {
                        //  domainNameLabel: 'jobvm-${uniqueString(resourceGroup().id)}'
                        //}
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
      'b499f0af-3d1a-4266-8fef-ada507b291df'  // Virtual Machine Scale Sets Contributor
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
          filePatterns: ['/opt/ingest/logs/*.log']
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
var storageName     = toLower('${suffix}sa${uniqueString(resourceGroup().id)}')
var planName        = '${suffix}-plan'
var functionAppName = '${suffix}-scale-func'

// 1) Storage Account for FUNCTIONS runtime
resource storage 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageName
  location: resourceGroup().location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
}

// 2) Consumption (Dynamic) plan
resource plan 'Microsoft.Web/serverfarms@2021-02-01' = {
  name: planName
  kind: 'functionapp'
  location: resourceGroup().location
  sku: {
    tier: 'Dynamic'
    name: 'Y1'
  }
}

// 3) Function App
resource func 'Microsoft.Web/sites@2021-02-01' = {
  name: functionAppName
  location: resourceGroup().location
  kind: 'functionapp'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    siteConfig: {
      appSettings: [
        { name: 'AzureWebJobsStorage',          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=core.windows.net'}
        { name: 'FUNCTIONS_WORKER_RUNTIME',     value: 'python'}
        { name: 'UAMI_CLIENT_ID',               value: uami.properties.clientId }
        { name: 'AZURE_SUBSCRIPTION_ID',        value: subscription().subscriptionId }
        { name: 'VMSS_RESOURCE_GROUP',          value: resourceGroup().name }
        { name: 'VMSS_NAME',                    value: vmssName }
        { name: 'VMSS_RESOURCE_ID',             value: vmss.id }
      ]
    }
  }
}

// 4) Define the function with both timer + HTTP trigger, inline code only
resource scaleFn 'Microsoft.Web/sites/functions@2022-03-01' = {
  parent: func
  name: 'ingest-trigger'
  properties: {
    config: {
      bindings: [
        {
          name: 'timer'
          type: 'timerTrigger'
          direction: 'in'
          schedule: '0 0 9 * * 1'           // every Monday 09:00 GMT
        }
        {
          authLevel: 'Function'
          type: 'httpTrigger'
          direction: 'in'
          name: 'req'
          methods: [ 'get', 'post' ]
        }
        {
          type: 'http'
          direction: 'out'
          name: 'res'
        }
      ]
    }
    files: {
      'run.py': '''
import os, azure.functions as func
from azure.identity import ManagedIdentityCredential
from azure.mgmt.compute import ComputeManagementClient

def main(timer: func.TimerRequest, req: func.HttpRequest) -> func.HttpResponse:
    ComputeManagementClient(
      credential=ManagedIdentityCredential(client_id=os.environ["UAMI_CLIENT_ID"]),
      subscription_id=os.environ["AZURE_SUBSCRIPTION_ID"]
    ).virtual_machine_scale_sets.begin_update(
      resource_group_name=os.environ["VMSS_RESOURCE_GROUP"],
      vm_scale_set_name=os.environ["VMSS_NAME"],
      sku={"capacity": 1}
    ).result()
    return func.HttpResponse("VMSS scaled to 1", status_code=200)
'''
    }
  }
}
