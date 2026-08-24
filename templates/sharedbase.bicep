@description('ACR name')
param registryName string

@description('Shared UAMI name, for UAMI with AcrPull role')
param uamiName string

@description('Shared Log Analytics workspace name')
param sharedLAW string

@description('Name of the managed identity the certificate-expiry alert rules (templates/certalerts.bicep) use to read Azure Resource Graph')
param certAlertUamiName string

/*
 * Azure Container Registry (Basic)
 */
resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: registryName
  location: resourceGroup().location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

// Create the UAMI in this RG
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: resourceGroup().location
}

// Assign AcrPull to the UAMI on the ACR
resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, uami.id, 'acrpull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull
    )
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

/*
 * Log Analytics Workspace
 */
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: sharedLAW
  location: resourceGroup().location
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

/*
 * Certificate-expiry alert identity
 *
 * Created here rather than in templates/certalerts.bicep (which only
 * consumes it via an `existing` reference) so that scripts/sharedalerts.sh
 * — which deploys certalerts.bicep and is documented to be re-run routinely
 * to raise and restore a test threshold (docs/operations.md) — does not
 * need to re-issue a roleAssignments PUT, and so does not need Owner /
 * User Access Administrator, on every such run. Only this bootstrap
 * deployment (scripts/shareddeploy.sh) needs that elevated role now; see
 * the note on the role assignment below.
 */
resource certAlertsUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: certAlertUamiName
  location: resourceGroup().location
}

// Reader at resource-group scope, not just on the Front Door profile: the
// identity needs to read both the profile's certificates (via ARG) and the
// Log Analytics workspace the certificate-expiry rules are scoped to, and
// both live in this resource group. This grant is also what bounds the
// certificate-expiry alerts to this resource group's certificates — the
// ARG query in templates/certalerts.bicep has no scope predicate of its
// own. That query lives far from this grant now that identity/RBAC has
// moved here, so this is the other end of that signpost: widening this
// grant silently widens what those alerts cover, and narrowing it (e.g. to
// the Front Door profile alone) would break the workspace access the same
// rules also need.
resource certAlertsReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, certAlertsUami.id, 'reader')
  properties: {
    principalId: certAlertsUami.properties.principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
    )
    principalType: 'ServicePrincipal'
  }
}
