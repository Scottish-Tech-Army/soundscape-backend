# Links site deployment

## Design

The links site is a once-only deployment (unlike iOS or Photon, there is no multi-instance cutover model). It serves three static files (one for Android, one for iOS, and one to allow health checks) and a redirect rule, both configured through Azure Front Door. See [architecture.md](architecture.md) for a full description.

All scripts in this procedure are idempotent — re-running on partial failure is safe.

## Prerequisites

- You must be logged into the correct Azure subscription.

- The shared infrastructure must already be deployed (`soundscape-shared` RG and `soundscape-fd` Front Door profile must exist).

## Instructions

- Source the config file.

    ~~~bash
    . config/links-cfg.sh
    ~~~

- Deploy the storage account and upload the static files.

    ~~~bash
    bash scripts/linksdeploy.sh
    ~~~

    This creates the `soundscape-links` RG, creates the storage account with static website hosting enabled, and syncs `src/links/` to the `$web` container.

    *On first run the script assigns the necessary Azure AD role for blob access; RBAC propagation can take a variable amount of time (normally a minute, occasionally longer if Entra is slow). If the sync step fails with a 403 permissions error, wait a minute or two and re-run the script.*

- Set up the DNS record and Front Door configuration for both the production domain (`links`) and once for the test domain (`linkstest`). Here `LABEL` must be either `links` or `linkstest`.

    ~~~bash
    bash scripts/linkszone.sh LABEL
    ~~~

    This creates the `LABEL-ep` AFD endpoint, custom domain, origin group, origin, route and rules engine rules, then creates a CNAME alias record for `LABEL` in the `soundscape.scottishtecharmy.org` DNS zone, pointing at that endpoint.

- Configure the custom domain certificate, for each domain in turn.

    - In [the portal](https://portal.azure.com), navigate to the `soundscape-fd` Front Door profile.

    - Select `Settings/Domains` on the left.

    - The `LABEL.soundscape.scottishtecharmy.org` domain will be in state *Domain validation needed*. Click on the `Validation state` (shown as *Pending*).

    - This will reveal the required TXT record value. Add that value as a `_dnsauth.LABEL` TXT record in the `soundscape.scottishtecharmy.org` DNS zone.


    - Wait for Front Door to complete TLS certificate provisioning. This may take up to 48 hours, but is normally far quicker (an hour or so is normal).

## Smoke test

Once the certificate is active, verify the two behaviours.

- Confirm the various static files are served correctly:

    - Android file

        ~~~bash
        curl -i "https://links.soundscape.scottishtecharmy.org/.well-known/assetlinks.json"
        ~~~

        Expected: HTTP 200, `Content-Type: application/json`, body containing the correct package name and certificate fingerprint.

    - iOS file

        ~~~bash
        curl -i "https://links.soundscape.scottishtecharmy.org/.well-known/apple-app-site-association"
        ~~~

        Expected: HTTP 200, `Content-Type: text/plain`, body containing the correct JSON.

    - Health check

        ~~~bash
        curl -i "https://links.soundscape.scottishtecharmy.org/.well-known/health"
        ~~~

        Expected: HTTP 200, body containing the text "OK".


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

## Operations

The links site is not actively monitored — there are no dedicated dashboards, alerts, or saved log queries in [operations.md](operations.md). Front Door health checks against `/.well-known/health` provide implicit availability monitoring (Front Door will mark the origin unhealthy if `health` stops returning 200), but this is not surfaced as an alert. If a problem is suspected, re-run the smoke test above.
