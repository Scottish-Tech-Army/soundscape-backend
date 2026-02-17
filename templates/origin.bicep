@description('The Front Door profile name')
param fdName string

@description('The Front Door origin group name')
param originGroupName string

@description('The FQDN of the target')
param targetFQDN string

@description('Path')
param probePath string

@description('HTTPS? May be HTTP instead')
param isHTTPS bool

@description('The port to use')
param port int

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
      probePath: probePath
      probeProtocol: isHTTPS ? 'Https' : 'Http'
      probeRequestType: 'GET'
      probeIntervalInSeconds: 120
    }
  }
}

resource origin 'Microsoft.Cdn/profiles/originGroups/origins@2023-05-01' = {
  parent: originGroup
  name: originGroupName
  properties: {
    hostName: targetFQDN
    httpsPort: isHTTPS ? port : null
    httpPort: isHTTPS ? null : port
    enforceCertificateNameCheck: isHTTPS
    originHostHeader: targetFQDN
  }
}
