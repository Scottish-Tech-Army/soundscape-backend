@description('The Front Door profile name')
param fdName string

@description('The Front Door origin group name')
param originGroupName string

@description('The FQDN of the tile server Container App')
param tilesrvFQDN string

resource afdProfile 'Microsoft.Cdn/profiles@2023-05-01' existing = {
  name: fdName
}

resource originGroup 'Microsoft.Cdn/profiles/originGroups@2023-05-01' = {
  parent: afdProfile
  name: originGroupName
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
    }
    healthProbeSettings: {
      probePath: '/metrics'
      probeProtocol: 'Https'
      probeRequestType: 'GET'
      probeIntervalInSeconds: 120
    }
  }
}

resource origin 'Microsoft.Cdn/profiles/originGroups/origins@2023-05-01' = {
  parent: originGroup
  name: originGroupName
  properties: {
    hostName: tilesrvFQDN
    httpsPort: 443
    enforceCertificateNameCheck: true
    originHostHeader: tilesrvFQDN
  }
}
