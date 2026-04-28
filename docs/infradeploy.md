# Infrastructure deployment and prerequisites to deployment

This document describes how to deploy common resources before you can deploy individual instances.

It covers the following.

- [Common prerequisites](#common-prerequisites) describes common prerequisites before you start anything.

- [Diagnostics infrastructure](#diagnostics-infrastructure) describes diagnostics infrastructure required by other components.

- [Shared resource group deployment](#shared-resource-group-deployment) describes how to deploy the shared resource group containing the Azure Front Door, Azure Container Registry, and DNS components.

- [Adding DNS zones and endpoints](#adding-dns-zones-and-endpoints) describes how to add the shared DNS zones and corresponding endpoints in Front Door for iOS and photon traffic.


## Common prerequisites

Before you can initially use any of the tooling to deploy any components, you need the following.

- A PC to run the tooling on. The tooling was tested using Linux, but anything running bash should be fine, including a Mac or WSL on Windows. This PC must have various utilities installed . These include the following.

    - [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)

    - [Docker](https://docs.docker.com/engine/install/)

    - [Azure functions core tools](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local?tabs=linux)

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

    - The necessary values to set are the following.

        - Filter to region `westeurope` for Android infrastructure, and ensure `Total Regional Spot vCPUs` is at least 32.

        - Filter to region `westeurope` for Android infrastructure, and ensure `Total Edsv6 Family vCPUs` is at least 32

        - Filter to region `northeurope` for iOS infrastructure, and ensure `Total Regional Spot vCPUs` is at least 32.

        - Filter to region `northeurope` for iOS infrastructure, and ensure `Total Edsv6 Family vCPUs` is at least 32.

        If you need to increase any quotas, you can edit them. If that does not work then issue a support request, which normally takes no more than an hour or two to be satisfied. *Spot VMs are not enabled at present; this is because there is a limitation thanks to our free Azure credits, which do not allow us to use spot VMs.*

## Diagnostics infrastructure

Diagnostics infrastructure is stored in a shared resource group, with both iOS and Android resources present in it. These resources are (to all intents and purposes) free, and there should be one such resource group in the subscription. They consist of

- an alert group (used as the target for alerts following errors elsewhere);

- Android and iOS query packs, simplifying searches through logs.

To deploy this infrastructure, follow the steps below.

- Set up a config file (this will have already been done for you - you should only ever change this if you are in the process of moving to another subscription or something).

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

- Set up a config file (this will have already been done for you - you should only ever change this if you are in the process of moving to another subscription or something).

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

- Once you have got traffic running through the Front Door (which only occurs later when you have created some deployments), you should set up the alerts. *Until some traffic has been logged by Front Door, this script will fail with cryptic errors.*

    ~~~bash
    bash scripts/sharedalerts.sh
    ~~~

## Adding DNS zones and endpoints

In order to add the shared DNS zones and corresponding endpoints in Front Door, you should do the following, for each of the relevant zones, which here we will denote as `ZONE` in the instructions. There are four relevant zones.

- `prd2` is for live iOS traffic

- `tst` is for test iOS traffic

- `photon` is for live photon search server traffic

- `photontest` is for test photon search server traffic

To deploy and configure them, follow the following process.

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
