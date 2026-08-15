#!/bin/bash
# Shared helper functions for the Front Door custom-domain zone scripts
# (scripts/sharedzone.sh, scripts/linkszone.sh). Sourced, not executed.
#
# Expects SHAREDRG, FRONTDOOR, DNS_SUFFIX and SUBSCRIPTION to already be set
# in the environment; this file does no configuration loading of its own.
#
# LABEL arguments must be validated by the caller. The ensure_* functions
# refuse an empty label or "@" as a backstop, but that is not a substitute.

# Install the CDN CLI extension. If already installed, this prints a message and
# succeeds. If we did not do this, and the extension was not installed,
# later commands would hang prompting for it. This is done at sourcing time.
az extension add --name cdn > /dev/null 2>&1

# afd_resource_id CHILD_TYPE NAME
# Echoes the full ARM resource ID of a child resource of the Front Door
# profile — e.g. afd_resource_id customDomains links. CHILD_TYPE is the ARM
# collection name, so it is camel-cased as ARM spells it (afdEndpoints,
# customDomains, ruleSets), not as the CLI spells the command.
#
# Needed because the cdn CLI extension takes linked resources by resource ID
# rather than by name: "az afd route create --formatted-custom-domains" and
# "--formatted-rule-sets" both want IDs, as does the DNS alias record's
# --target-resource. The IDs are constructed rather than looked up — every
# caller has just created or confirmed the resource, so a show call would only
# echo back a name it already has.
afd_resource_id() {
  echo "/subscriptions/${SUBSCRIPTION}/resourceGroups/${SHAREDRG}/providers/Microsoft.Cdn/profiles/${FRONTDOOR}/$1/$2"
}

# ensure_endpoint_and_domain LABEL
# Creates the AFD endpoint "${LABEL}-ep" and the AFD custom domain "${LABEL}"
# (host name "${LABEL}.${DNS_SUFFIX}", ManagedCertificate), each guarded by
# check-then-create idempotency so re-running makes no changes once both exist.
ensure_endpoint_and_domain() {
  local label="$1"
  # See ensure_dns_alias for why this guard exists.
  [[ -n "${label}" && "${label}" != "@" ]] || {
    echo "Error: zone label must be non-empty and must not be '@'" >&2
    return 1
  }

  # One endpoint per domain label: "photon" -> photon-ep, "photontest" ->
  # photontest-ep. The live and test domains deliberately have separate
  # endpoints pointing at the same backing location — that is what makes a
  # cutover possible: stand up a new backing location, point the test
  # endpoint at it and check it works, then repoint the live endpoint. A
  # shared endpoint would leave nowhere to test from.
  local endpoint_name="${label}-ep"
  local host_name="${label}.${DNS_SUFFIX}"

  if az afd endpoint show \
      -g "${SHAREDRG}" \
      --profile-name "${FRONTDOOR}" \
      -n "${endpoint_name}" \
      >/dev/null 2>&1
  then
    echo "AFD endpoint ${endpoint_name} already exists"
  else
    echo "Creating AFD endpoint ${endpoint_name}"
    az afd endpoint create \
      -g "${SHAREDRG}" \
      --profile-name "${FRONTDOOR}" \
      -n "${endpoint_name}" \
      --enabled-state Enabled
  fi

  if az afd custom-domain show \
      -g "${SHAREDRG}" \
      --profile-name "${FRONTDOOR}" \
      -n "${label}" \
      >/dev/null 2>&1
  then
    echo "AFD custom domain ${label} already exists"
  else
    echo "Creating AFD custom domain ${label}"
    az afd custom-domain create \
      -g "${SHAREDRG}" \
      --profile-name "${FRONTDOOR}" \
      -n "${label}" \
      --host-name "${host_name}" \
      --certificate-type ManagedCertificate
  fi
}

# ensure_dns_alias LABEL
# Points "${LABEL}.${DNS_SUFFIX}" at the AFD endpoint "${LABEL}-ep" via a
# CNAME alias record in the parent zone "${DNS_SUFFIX}". Any leftover NS
# delegation for LABEL is removed first — Azure DNS refuses a CNAME record
# set for a name that still carries an NS record set — and on a green-field
# label there is none to remove, so this is a no-op there.
#
# This never creates or deletes a DNS zone: the child zone a converted domain
# used to be delegated to (if any) is left alone as the rollback path.
ensure_dns_alias() {
  local label="$1"
  # Backstop only: every caller already whitelists its label, so this cannot
  # fire today. The Azure CLI does NOT reject
  # "record-set ns delete -n ''" client-side, and an empty relative record
  # name is protocol-equivalent to the zone apex — so a caller that passed an
  # empty string would delete the parent zone's own NS record set and detach
  # every domain under it. "@" is the same thing spelled explicitly.
  [[ -n "${label}" && "${label}" != "@" ]] || {
    echo "Error: zone label must be non-empty and must not be '@'" >&2
    return 1
  }

  local endpoint_name="${label}-ep"
  local target
  target="$(afd_resource_id afdEndpoints "${endpoint_name}")"

  if az network dns record-set ns show \
      -g "${SHAREDRG}" \
      -z "${DNS_SUFFIX}" \
      -n "${label}" \
      >/dev/null 2>&1
  then
    echo "Removing stale NS delegation for ${label} in ${DNS_SUFFIX}"
    az network dns record-set ns delete \
      -g "${SHAREDRG}" \
      -z "${DNS_SUFFIX}" \
      -n "${label}" \
      --yes
  else
    echo "No NS delegation for ${label} in ${DNS_SUFFIX}"
  fi

  # Between the delete above and the create below the label resolves to
  # nothing - but this is unavoidable and should only last a fraction of a second.
  if az network dns record-set cname show \
      -g "${SHAREDRG}" \
      -z "${DNS_SUFFIX}" \
      -n "${label}" \
      >/dev/null 2>&1
  then
    echo "DNS CNAME record ${label} in ${DNS_SUFFIX} already exists"
  else
    echo "Creating DNS CNAME record ${label} in ${DNS_SUFFIX} -> ${target}"
    az network dns record-set cname create \
      -g "${SHAREDRG}" \
      -z "${DNS_SUFFIX}" \
      -n "${label}" \
      --target-resource "${target}"
  fi
}
