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
param genRegions string = 'europe'

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
    }
    protectedSettings: {
      // force the right API version so Bicep can pull the key
      //workspaceKey: listKeys(logAnalytics.id, '2022-08-01').primarySharedKey
      workspaceKey: logAnalytics.listKeys().primarySharedKey
    }
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
