# Infrastructure deployment and prerequisites to deployment

This document describes how to deploy the common infrastructure that must exist before you can deploy any individual iOS, Android, photon, or links instance.

## Deploying common infrastructure from scratch

To stand up the common infrastructure in a fresh subscription, work through these in order:

1. [Common prerequisites](#common-prerequisites) — install the tooling, log in to the subscription, and set quotas. Do this first, once per subscription/operator.

2. [Diagnostics infrastructure](#diagnostics-infrastructure) — the shared alert group and log query packs that the other components depend on.

3. [Shared resource group deployment](#shared-resource-group-deployment) — Azure Front Door, the Container Registry, DNS, and the shared Log Analytics workspace.

4. [Usage-metrics resource group deployment](#usage-metrics-resource-group-deployment) — the long-term usage-metrics database and its shared reader.

5. [Adding DNS records and endpoints](#adding-dns-records-and-endpoints) — the shared DNS records and corresponding Front Door endpoints for iOS and photon traffic.

With the common infrastructure in place, deploy individual instances using their own documents: [iOS](iosdeploy.md), [Android](androiddeploy.md), [photon](photondeploy.md), and the [links site](linksdeploy.md).

The remaining sections are reference material used by several of the steps above:

- The [Config file convention](#config-file-convention)

- The [Note on spot VMs](#note-on-spot-vms)

- The [Front Door cutover pattern](#front-door-cutover-pattern) (the test-then-cut-over flow shared by the iOS and photon procedures).

## Common prerequisites

Before you can initially use any of the tooling to deploy any components, you need the following.

- A PC to run the tooling on. The tooling was tested using Linux, but anything running bash should be fine, including a Mac or WSL on Windows. This PC must have various utilities installed. The tools are as follows.

    - [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) — required for all components.

    - [Docker](https://docs.docker.com/engine/install/) (any recent version) — required for components that build container images: iOS (`iosbuild.sh`) and photon (`photonbuild.sh`).

    - [Azure functions core tools](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local?tabs=linux) (v4) — required for components that publish function apps via `functionapp.sh`: iOS, Android, and photon.

    - Python 3.12 — only required if you want to run function app code locally. Not needed for normal deployment, since `func azure functionapp publish` builds in the cloud.

    - The `psql` PostgreSQL client — required for the usage-metrics schema step (`metricsschema.sh`), which applies SQL to the metrics database.

    - Various other CLI tools such as `jq` and `curl`, required by various scripts.

    - The contents of this repo checked out locally, to allow running of the various scripts.

- Access to the Azure subscription which contains all of the resources in question. You should log into the Tech For Good Alliance tenant before you run any other commands.

    ~~~bash
    az login --use-device-code
    az account show
    ~~~

    If necessary, you can log in using a different account, or use `az account set` to reset which subscription is in use.

- Quotas must be set for the subscription.

    - Go to the [Azure portal](https://portal.azure.com)

    - Select your subscription

    - In the left hand section, select `Settings/Usage + quotas`.

    - The necessary values to set are the following. Spot quotas are only required if you intend to enable spot VMs for a deployment (`USE_SPOT=true` in the per-deployment config); see [Note on spot VMs](#note-on-spot-vms) below.

        - Filter to region `westeurope` for Android infrastructure, and ensure `Total Edsv6 Family vCPUs` is at least 32.

        - Filter to region `northeurope` for iOS infrastructure, and ensure `Total Edsv6 Family vCPUs` is at least 32.

        - If using spot VMs, additionally ensure `Total Regional Spot vCPUs` is at least 32 in each of `westeurope` (Android) and `northeurope` (iOS).

        If you need to increase any quotas, you can edit them. If that does not work then issue a support request, which normally takes no more than an hour or two to be satisfied.

### Note on spot VMs

Spot VMs are significantly cheaper than standard VMs, and the configuration files include a `USE_SPOT` flag to enable them per deployment. However, spot VMs are not currently enabled for the live deployments because the free Azure credits used by this project do not permit spot allocation. Set `USE_SPOT=false` in your config unless you know your subscription supports spot VMs.

## Diagnostics infrastructure

Diagnostics infrastructure is stored in a shared resource group, with both iOS and Android resources present in it. These resources are (to all intents and purposes) free, and there should be one such resource group in the subscription. They consist of

- an alert group (used as the target for alerts following errors elsewhere);

- Android and iOS query packs, simplifying searches through logs.

To deploy this infrastructure, follow the steps below.

- Set up a config file (see [Config file convention](#config-file-convention)).

    - The file should be in the [config](config) directory, and be named `diags-cfg.sh`

    - Contents should be as below; see comments.

        ~~~bash
        # Diags configuration
        # Region and RG
        export DIAGSREGION=westeurope
        export DIAGSRG=soundscape-diags

        # Subscription
        export SUBSCRIPTION=9ff2d6b4-099b-4370-9629-6f490b4ac356
        ~~~

- Source the config file.

    ~~~bash
    . config/diags-cfg.sh
    ~~~

- Load the shared queries and alert group.

    ~~~bash
    bash scripts/diagsdeploy.sh
    ~~~

- Configure the alert group that will handle all alerts, created above. This is done through the portal so that we do not need to check in people's email addresses in git repositories.

    - Go to the [Azure portal](https://portal.azure.com).

    - Find the resource group you set up above (something like `soundscape-diags` with the default configuration).

    - Edit the `Action group` in that subscription.

        - Under `Notifications`, select `Notification type` of `Email/SMS message/Push/Voice` (from the dropdown)

        - Give it a name - "soundscape" is fine

        - Hit the edit button and add whatever emails should receive alerts.

        - Hit the save button

## Shared resource group deployment

Shared infrastructure contains the Azure Front Door, Azure Container Registry, and DNS components for the deployment. To deploy this infrastructure, follow the steps below.

- Set up a config file (see [Config file convention](#config-file-convention)).

    - The file should be in the [config](config) directory, and be named `shared-cfg.sh`

    - Contents should be as below; see comments.

        ~~~bash
        # Shared RG configuration
        # Region and RG
        export SHAREDREGION=westeurope
        export SHAREDRG=soundscape-shared
        export SHAREDLAW=shared-law
        export REGISTRYNAME=soundscape
        export REGISTRYRG=$SHAREDRG
        export REGISTRYUAMI=registry-uami
        export FRONTDOOR=soundscape-fd

        # Subscription
        export SUBSCRIPTION=9ff2d6b4-099b-4370-9629-6f490b4ac356
        ~~~

- Source the config file.

    ~~~bash
    . config/shared-cfg.sh
    ~~~

- Run the script to create the shared resource group and set up resources within it.

    ~~~bash
    bash scripts/shareddeploy.sh
    ~~~

- Once traffic is flowing through Front Door (which only happens after the first deployment is up), set up the alerts. *Until some traffic has been logged by Front Door, this script will fail with cryptic errors.*

    ~~~bash
    bash scripts/sharedalerts.sh
    ~~~

## Usage-metrics resource group deployment

The usage-metrics store is shared infrastructure — one per subscription, in its own `soundscape-metrics` resource group — holding long-term usage metrics for Superset. See [architecture.md](architecture.md#usage-metrics-architecture) for what it is and why. **Deploy it after the shared resource group and before any Android instance**, because the Android deploy reads this deployment's outputs and grants its reader access to the database.

This step needs the `psql` client installed locally (see [Common prerequisites](#common-prerequisites)). The relevant configuration already lives in `shared-cfg.sh`:

~~~bash
# The metrics stack lives in its own RG.
export METRICS_RG=soundscape-metrics
export METRICS_REGION=uksouth

# Superset source IP for the database firewall rule. Leave blank until it is known.
export METRICS_SUPERSET_IP=
~~~

- Source the shared config.

    ~~~bash
    . config/shared-cfg.sh
    ~~~

- Deploy the database, Key Vault, and the shared reader function app.

    ~~~bash
    bash scripts/metricsdeploy.sh
    ~~~

- Apply the database schema and access control — the `usage_metrics` table, the reader's Entra-mapped writer role, and the read-only `superset_ro` role (whose password is generated once into Key Vault).

    ~~~bash
    bash scripts/metricsschema.sh
    ~~~

- Publish the shared reader's code. (`functionapp.sh` takes the target resource group as an argument and publishes the function apps it finds there — here just the shared reader.)

    ~~~bash
    bash scripts/functionapp.sh ${METRICS_RG}
    ~~~

- Populate history by triggering the reader's backfill once: in the portal, open the `usagemetrics-*` function app in `soundscape-metrics`, select the `usagemetrics_backfill` function, and use `Code & Test → Test/Run` (optionally with a `days` query parameter). The nightly timer keeps it current thereafter.

### Notes

- **`metricsschema.sh` must be run by the same operator who ran `metricsdeploy.sh`.** That deploy binds both the database's Entra admin and the Key Vault secret-write permission to that operator's identity, so a different user would have neither and the step would fail. If operators must change, re-run the idempotent `metricsdeploy.sh` as the new operator first (it re-grants both). `metricsschema.sh` opens a temporary firewall rule for your workstation for the duration of the run and removes it on exit.

- Both scripts are idempotent and safe to re-run. Once Superset's egress IP is known, set `METRICS_SUPERSET_IP` in `shared-cfg.sh` and re-run `metricsschema.sh` to add its firewall rule — that rule lives in `metricsschema.sh`, not the deployment template, so re-running `metricsdeploy.sh` will not add it.

## Adding DNS records and endpoints

In order to add the shared DNS records and corresponding endpoints in Front Door, you should do the following, for each of the relevant domains, which here we will denote as `ZONE` in the instructions. There are four relevant domains.

- `prd2` is for live iOS traffic

- `tst` is for test iOS traffic

- `photon` is for live photon search server traffic

- `photontest` is for test photon search server traffic

To deploy and configure them, follow these steps.

-  Source the config file.

    ~~~bash
    . config/shared-cfg.sh
    ~~~

- Create the DNS record and custom domain

    ~~~bash
    bash scripts/sharedzone.sh ZONE
    ~~~

    This creates a CNAME alias record for `ZONE` in the `soundscape.scottishtecharmy.org` DNS zone, pointing at the Front Door endpoint. The script works out from the domain whether to configure an iOS or a photon endpoint.

- Validate the Front Door custom domain

    - Go to the Front Door instance, `soundscape-fd` in the `soundscape-shared` resource group.

    - Expand `Settings` on the left.

    - Click on `Domains`.

    - You should see your domain, which will be in state `Domain validation needed`.

    - Click on the `Validation state` which should show `Pending`.

    - Add the TXT record, named `_dnsauth.ZONE`, to the `soundscape.scottishtecharmy.org` parent DNS zone with the value supplied.

        This is a one-off step: because `ZONE` is a CNAME pointing directly at the Front Door endpoint, Front Door revalidates the certificate automatically at renewal, so this record does not need to be added again for the life of the domain (see [Microsoft's Front Door domains documentation](https://learn.microsoft.com/en-us/azure/frontdoor/domain), "Certificate renewal").

    - Wait for the validation to complete. Periodically refresh the `Domains` pane until the validation state changes from `Pending` to `Approved`. This normally takes a few minutes but can occasionally take a few hours.

- Wait for Front Door to provision the TLS certificate. Once the domain is approved, Front Door automatically issues a managed certificate. The certificate state on the `Domains` pane will change from `Issuing` to `Approved`. This typically takes under an hour but can take up to 48 hours.

- Verify the zone is live. The route created by `sharedzone.sh` initially points at the `dummy-blackhole` origin group, so a request returns an error from the dummy origin rather than a TLS or DNS failure. A successful response (any HTTP status from the dummy origin, not a connection or certificate error) confirms the zone, route, and certificate are all correctly wired up:

    ~~~bash
    curl -i "https://ZONE.soundscape.scottishtecharmy.org/"
    ~~~

    The route can later be repointed at a real origin group by the iOS or photon deployment process.

## Front Door cutover pattern

The iOS and photon deployment procedures both end with a "test then cut over" step that switches Front Door routes from the previous deployment to the new one. The shape of that step is the same in both cases, so it is documented here once and referred to from both procedures. The steps below use the following placeholders:

- `<TEST_ENDPOINT>` — the test domain (e.g. `tst` for iOS, `photontest` for photon)
- `<PROD_ENDPOINT>` — the production domain (e.g. `prd2` for iOS, `photon` for photon)
- `<SMOKE_URL>` — a URL that exercises the deployment end-to-end (varies by component)
- `<LOADTEST_CMD>` — the per-component load-test command, run with the endpoint name as its argument

The per-component values are listed in the iOS and photon deployment documents, which link back to this section.

### Route test traffic to the new deployment

Switching the test route is the first cutover step: it makes the test endpoint resolve to your new deployment so the subsequent smoke-test and load-test exercise the new instance.

- Open the Azure Front Door instance (the only one, in the `soundscape-shared` resource group) in the [portal](https://portal.azure.com). All steps below operate on this resource.

- Select `Origin Groups` on the left panel and confirm the origin group for your new deployment is present (it was created by `iosorigin.sh` or `photonorigin.sh`).

- Repoint the test route.

    - Click `Front Door manager`.

    - Click the `<TEST_ENDPOINT>.soundscape.scottishtecharmy.org` endpoint.

    - Click on the route under that endpoint.

    - Change the origin group to the one for your new deployment.

- Smoke-test the test endpoint. Requests now hit the new deployment:

    ~~~bash
    curl -i "<SMOKE_URL>"
    ~~~

    The `nocache` query parameter (where present in `<SMOKE_URL>`) bypasses Front Door cache. Confirm a successful response.

### Load-test the test endpoint

This is the main correctness gate. The load test runs in your local shell and writes results to the current directory.

- Pick a directory for the test outputs and `cd` to it.

- Run the load test against the test endpoint:

    ~~~bash
    nohup <LOADTEST_CMD> <TEST_ENDPOINT> &
    ~~~

- Tail the output log and the CSV results file as the test runs. Wait for the test to complete before treating it as a success — early samples can pass while later ones fail. Load should be visible against your new deployment in the dashboard.

### Cut over production traffic

Only proceed once the load test against `<TEST_ENDPOINT>` has fully completed without errors.

- From your test directory, start the load test against the production endpoint *before* changing the route:

    ~~~bash
    nohup <LOADTEST_CMD> <PROD_ENDPOINT> &
    ~~~

    Initially this will continue to hit the previous deployment, which is the point — it gives you a continuous in-flight measurement across the route change.

- Repoint the production route.

    - Click `Front Door manager`.

    - Click the `<PROD_ENDPOINT>.soundscape.scottishtecharmy.org` endpoint.

    - Click on the route and change the origin group to the one for your new deployment.

- Verify the cutover.

    - The load-test output should continue to show no errors across the route change.

    - Load should now be arriving at your new deployment in the dashboard, and falling away on the previous one.

- Once you are satisfied, the previous deployment can be left running for rollback safety and deleted later, or torn down immediately if you have already validated the deployment elsewhere.

## Config file convention

Each deployment procedure begins by sourcing a config file under `config/`. These config files are pre-checked-in for the live deployments — you should only edit them if you are moving to another subscription, changing region, or similar. When a procedure says "set up a config file", it is documenting what the file should contain rather than asking you to write it from scratch. The deploy scripts assume the config has already been sourced into your shell.
