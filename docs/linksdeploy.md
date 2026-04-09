# Links site deployment

## Design

The links site is a once-only deployment (unlike iOS or Photon, there is no multi-instance cutover model). It serves a single static file and a redirect rule, both configured through Azure Front Door. See [architecture.md](architecture.md) for a full description.

## Prerequisites

- You must be logged into the correct Azure subscription.
- The shared infrastructure must already be deployed (`soundscape-shared` RG and `soundscape-fd` Front Door profile must exist).

## Instructions

All scripts are idempotent.

- Source the config file.

    ~~~bash
    . config/links-cfg.sh
    ~~~

- Deploy the storage account and upload the `assetlinks.json` file.

    ~~~bash
    bash scripts/linksdeploy.sh
    ~~~

    This creates the `soundscape-links` RG, creates the storage account with static website hosting enabled, and syncs `src/links/` to the `$web` container.

    *On first run the script assigns the necessary Azure AD role for blob access; RBAC propagation can take a variable amount of time (normally a minute, occasionally longer if Entra is slow). If the sync step fails with a 403 permissions error, wait a minute or two and re-run the script.*

- Set up the DNS zone and Front Door configuration.

    ~~~bash
    bash scripts/linkszone.sh
    ~~~

    This creates the `links.soundscape.scottishtecharmy.org` DNS zone as a child of the existing `soundscape.scottishtecharmy.org` zone (NS delegation is handled automatically), then creates the AFD endpoint, custom domain, route, and rules engine rules.

- Configure the custom domain certificate.

    - In [the portal](https://portal.azure.com), navigate to the `soundscape-fd` Front Door profile.

    - Select `Settings/Domains` on the left.

    - The `links.soundscape.scottishtecharmy.org` domain will be in state *Domain validation needed*. Click on the `Validation state` (shown as *Pending*).

    - This will reveal the required TXT record value, then add that `_dnsauth` TXT record to the `links.soundscape.scottishtecharmy.org` DNS zone.

    Wait for Front Door to complete TLS certificate provisioning. This may take up to 48 hours, but is normally far quicker (an hour or so is normal).

## Smoke test

Once the certificate is active, verify the two behaviours.

- Confirm the asset links file is served correctly:

    ~~~bash
    curl -i "https://links.soundscape.scottishtecharmy.org/.well-known/assetlinks.json"
    ~~~

    Expected: HTTP 200, `Content-Type: application/json`, body containing the correct package name and certificate fingerprint.

- Confirm the catch-all redirect works:

    ~~~bash
    curl -i "https://links.soundscape.scottishtecharmy.org/"
    ~~~

    Expected: HTTP 301, `Location: https://scottish-tech-army.github.io/Soundscape-Android/`.

- Confirm HTTP is redirected to HTTPS:

    ~~~bash
    curl -i "http://links.soundscape.scottishtecharmy.org/"
    ~~~

    Expected: HTTP 301 or 302 redirect to the HTTPS equivalent.
