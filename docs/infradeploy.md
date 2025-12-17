# Infrastructure deployment and prerequisites to deployment

This document describes how to deploy common resources before you can deploy individual instances.

It covers the following.

- [Common prerequisites](#common-prerequisites) describes common prerequisites before you start anything.

- [Diagnostics infrastructure](#diagnostics-infrastructure) describes diagnostics infrastructure required by other components.


## Common prerequisites

Before you can initially use any of the tooling to deploy any components, you need the following.

- A PC to run the tooling on. The tooling was tested using Linux, but anything running bash should be fine, including a Mac or WSL on Windows. This PC must have various utilities installed . These include the following.

    - [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)

    - [Docker](https://docs.docker.com/engine/install/)

    - [Azure functions core tools](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local?tabs=linux)

    - The contents of this repo checked out locally, to allow running of the various scripts.

- Access to the Azure subscription which contains all of the resources in question. You should log into the relevant tenant before you run any other commands.

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

        If you need  to increase any quotas, you can edit them. If that does not work then issue a support request, which normally takes no more than an hour or two to be satisfied.


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
        export SUBSCRIPTION=c45947c8-2a50-4f53-bdf1-1fb282636578
        ~~~

- Source the config file.

    ~~~bash
    . config/diags-cfg.sh
    ~~~

- Load the shared queries and alert group.

    ~~~bash
    bash scripts/diagsdeploy.sh
    ~~~

- Configure the alert group that will handle all alerts. This is done through the portal so that we do not need to check in people's email addresses in git repositories.

    - Go to the [Azure portal](https://portal.azure.com).

    - Find the resource group you set up above (something like `soundscape-diags` with the default configuraiton).

    - Edit the `Action group` in that subscription.

        - Under `Notifications`, select `Notification type` of `Email/SMS message/Push/Voice` (from the dropdown)

        - Give it a name - "soundscape" is fine

        - Hit the edit button and add whatever emails should receive alerts.

        - Hit the save button








