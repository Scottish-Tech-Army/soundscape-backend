// Certificate-expiry alerts (cert-expiry-alerts, issue #46).
//
// Two scheduled query rules that warn ahead of a Front Door managed
// certificate expiring: an early, low-severity warning and a later,
// high-severity one. Both query Azure Resource Graph directly via arg("")
// rather than the Log Analytics workspace, since nothing in the deployment
// writes certificate expiry data into the workspace. The reasoning behind
// each non-obvious choice is inlined below, so this file stands alone.
//
// An ARG query in a scheduled query rule requires a managed identity (Azure
// gives rules no permissions on ARG under the default 'None' identity
// option). That identity and its Reader grant on the shared resource group
// are created in templates/sharedbase.bicep, not here — see the comments on
// certAlertsUami and certAlertsReader in that file for why — so this
// template only references the identity by name.

@description('ID of the shared Log Analytics workspace the rules are scoped to')
param logAnalyticsId string

@description('RG holding the Soundscape action group that receives the alert emails')
param diagsRG string

@description('Name of the Action Group')
param actionGroupName string = 'soundscape'

@description('Name of the pre-existing managed identity used to read Azure Resource Graph and the Log Analytics workspace these rules are scoped to')
param certAlertUamiName string

// @minValue(1) on both: the query below is assembled by string
// interpolation, not arithmetic, so any value below 1 makes earlyLowerBound
// (earlyDays - 1) negative and the interpolated clause becomes `ago(--Nd)`
// - invalid KQL and so the alert will never fire.
@description('Days-to-expiry threshold for the early warning.')
@minValue(1)
param earlyDays int

@description('Days-to-expiry threshold for the imminent-expiry alert. Fires daily for every certificate inside this threshold.')
@minValue(1)
param imminentDays int

// Lower bound of the early-warning band, derived here so the threshold is
// still "one edit in one place" in config/shared-cfg.sh: changing earlyDays
// moves both bounds together.
var earlyLowerBound = earlyDays - 1

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' existing = {
  name: actionGroupName
  scope: resourceGroup(diagsRG)
}

resource certAlertsUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: certAlertUamiName
}

// Reads every managed certificate this identity can see (i.e. every
// certificate in this resource group's Front Door profile — see the Reader
// grant referenced above) and returns one row per certificate expiring
// within the threshold. `ago(-Nd)` is "now plus N days"; this reads oddly
// but is deliberate — date subtraction (datetime_diff and friends) could
// not be made to work against arg(). expiryDate is a formatted string, not
// a datetime, because alert dimensions only accept string/numeric columns.
//
// queryPrefix deliberately stops mid-statement at `| where`, and the
// threshold clause is interpolated onto it below. The space separating the
// two is written into the interpolation rather than left as trailing
// whitespace inside the literal, where it would be both invisible to a
// reviewer and load-bearing: losing it yields `| wherecertExp < ...`, which
// fails to execute, and this feature does not alert on its own failure.
var queryPrefix = '''
arg("").cdnresources
| where type == "microsoft.cdn/profiles/secrets"
| extend subject = tostring(properties.parameters.subject),
         certExp = todatetime(properties.parameters.expirationDate)
| where isnotempty(subject) and isnotnull(certExp)
| where'''

var querySuffix = '''

| extend expiryDate = format_datetime(certExp, 'yyyy-MM-dd')
| project subject, expiryDate
'''

var earlyQuery = '${queryPrefix} certExp < ago(-${earlyDays}d) and certExp >= ago(-${earlyLowerBound}d)${querySuffix}'
var imminentQuery = '${queryPrefix} certExp < ago(-${imminentDays}d)${querySuffix}'

// Splitting on subject/expiryDate makes Azure fire one alert instance per
// affected certificate and puts both values in the notification, so an
// email names the domain and the deadline without a custom message
// template. A day count is deliberately not used as a dimension: Azure treats
// a dimension value that changes on every evaluation as a new alert instance,
// which defeats muteActionsDuration entirely and would mail on all four
// daily evaluations.
// A certificate's expiry date is fixed for its lifetime, so it splits cleanly.
var certDimensions = [
  {
    name: 'subject'
    operator: 'Include'
    values: ['*']
  }
  {
    name: 'expiryDate'
    operator: 'Include'
    values: ['*']
  }
]

// Early warning fires once as a certificate crosses the early threshold:
// the one-day-wide band [earlyLowerBound, earlyDays) is passed through
// exactly once per certificate. muteActionsDuration's PT24H maximum means
// the four PT6H evaluations that see the same certificate inside the band
// still send only one mail. Imminent expiry has no such band: it matches
// everything inside its threshold and repeats daily (muted for a day between
// evaluations).
var certRules = [
  {
    name: 'cert-expiry-early-warning'
    displayName: 'Certificate expiry: early warning'
    description: 'A Front Door managed certificate will expire soon, and should be checked.'
    severity: 3
    query: earlyQuery
  }
  {
    name: 'cert-expiry-imminent'
    displayName: 'Certificate expiry: imminent'
    description: 'A Front Door managed certificate is about to expire and needs URGENT attention.'
    severity: 1
    query: imminentQuery
  }
]

// API version 2023-12-01 or later required to support identity.
resource certAlertRules 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [for rule in certRules: {
  name: rule.name
  location: resourceGroup().location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${certAlertsUami.id}': {}
    }
  }
  properties: {
    displayName: rule.displayName
    description: rule.description
    enabled: true
    severity: rule.severity

    evaluationFrequency: 'PT6H'

    // Mandatory but inert: aggregation granularity does not filter an arg()
    // query, so this does not affect what the query returns. Azure requires
    // it to be no smaller than evaluationFrequency, hence PT6H rather than
    // the PT1H that templates/alert.bicep defaults to.
    windowSize: 'PT6H'

    // Required even though the query reads ARG rather than the workspace.
    scopes: [
      logAnalyticsId
    ]

    criteria: {
      allOf: [
        {
          query: rule.query
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          dimensions: certDimensions
        }
      ]
    }

    muteActionsDuration: 'PT24H'
    autoMitigate: false

    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}]
