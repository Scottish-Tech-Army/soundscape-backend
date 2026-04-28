# Infrastructure deployment and prerequisites to deployment

This document describes how to deploy common resources before you can deploy individual instances.

It covers the following.

- [Common prerequisites](#common-prerequisites) describes common prerequisites before you start anything.

- [Diagnostics infrastructure](#diagnostics-infrastructure) describes diagnostics infrastructure required by other components.

- [Shared resource group deployment](#shared-resource-group-deployment) describes how to deploy the shared resource group containing the Azure Front Door, Azure Container Registry, and DNS components.

- [Adding DNS zones and endpoints](#adding-dns-zones-and-endpoints) describes how to add the shared DNS zones and corresponding endpoints in Front Door for iOS and photon traffic.

- [Front Door cutover pattern](#front-door-cutover-pattern) is a shared appendix describing the test-then-cut-over flow used by both the iOS and photon deployment procedures.

## Config file convention

Each deployment procedure begins by sourcing a config file under `config/`. These config files are pre-checked-in for the live deployments — you should only edit them if you are moving to another subscription, changing region, or similar. When a procedure says "set up a config file", it is documenting what the file should contain rather than asking you to write it from scratch. The deploy scripts assume the config has already been sourced into your shell.

## Common prerequisites

Before you can initially use any of the tooling to deploy any components, you need the following.

- A PC to run the tooling on. The tooling was tested using Linux, but anything running bash (4.0+) should be fine, including a Mac or WSL on Windows. This PC must have various utilities installed. The tools, which components require them, and tested versions are as follows.

    - [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (2.50 or later) — required for all components.

    - [Docker](https://docs.docker.com/engine/install/) (any recent version) — required for components that build container images: iOS (`iosbuild.sh`) and photon (`photonbuild.sh`).

    - [Azure functions core tools](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local?tabs=linux) (v4) — required for components that publish function apps via `functionapp.sh`: iOS, Android, and photon.

    - Python 3.12 — only required if you want to run function app code locally. Not needed for normal deployment, since `func azure functionapp publish` builds in the cloud.

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

## Adding DNS zones and endpoints

In order to add the shared DNS zones and corresponding endpoints in Front Door, you should do the following, for each of the relevant zones, which here we will denote as `ZONE` in the instructions. There are four relevant zones.

- `prd2` is for live iOS traffic

- `tst` is for test iOS traffic

- `photon` is for live photon search server traffic

- `photontest` is for test photon search server traffic

To deploy and configure them, follow these steps.

-  Source the config file.

    ~~~bash
    . config/shared-cfg.sh
    ~~~

- Create the DNS zone and custom domain; here `TYPE` must be either `ios` or `photon`

    ~~~bash
    bash scripts/sharedzone.sh ZONE TYPE
    ~~~

    Note that this will automatically add the correct `NS` records in the parent `soundscape.scottishtecharmy.org` DNS zone.

- Validate the Front Door custom domain

    - Go to the Front Door instance, `soundscape-fd` in the `soundscape-shared` resource group.

    - Expand `Settings` on the left.

    - Click on `Domains`.

    - You should see your domain, which will be in state `Domain validation needed`.

    - Click on the `Validation state` which should show `Pending`.

    - Add the TXT record (`_dnsauth`) to the `ZONE` DNS zone with the value supplied.

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
