# Deployment and management

This document describes how to deploy a new deployment. It does not cover the global shared resources (which are assumed to exist).

The process is as follows.

- Check some [prerequisites](#prerequisites)

- [Set up your deployment in Azure](#deploying-in-azure).

- [Test that it all works](#testing-that-your-deployment-works).

- [Cut over live traffic to your new deployment](#switching-over-to-your-deployment).

## Prerequisites

Before you can initially create a deployment, you need the following.

- A PC to run the tooling on. The tooling was tested using Linux, but anything running bash should be fine, including a Mac or WSL on Windows. This PC must have various utilities installed . These include the following.

    - [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)

    - [Docker](https://docs.docker.com/engine/install/)

    - [Azure functions core tools](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local?tabs=linux)

    - Various scripts contained in this repo, which must be checked out.

- An Azure subscription. This will contain the various components that get deployed.

## Deploying in Azure

Follow the following steps.

- Set up a config file. *TODO: document with an example.*


- Source the config file.

    ~~~bash
    . config/my_config_file.sh
    ~~~

- Ensure that you have created an Azure subscription to use, and that you are logged into Azure, defaulting to that subscription.

    ~~~bash
    az login --use-device-code
    az account show
    ~~~

    If necessary, you can log in using a different account, or use `az account set` to reset which subscription is in use.

- Build and upload images.

    ~~~bash
    bash scripts/build.sh
    ~~~

- Run the deploy script.

    ~~~bash
    bash scripts/deploy.sh
    ~~~

- Run the second half of the deployment (should combine with above).

    ~~~bash
    bash scripts/vm.sh
    ~~~

- Deploy the function app code.

    ~~~bash
    bash scripts/functionapp.sh
    ~~~

## Deploying log queries

There are some saved queries shared across all deployments. These exist in a single resource group, and so you should not need to change these. If you make changes, you can deploy them as follows.

~~~bash
bash scripts/functionapp.sh
~~~

### Redeploy gotchas

If you redeploy the various bicep templates, some bad things happen. I should really fix these up.

- If you reload the `deploy` template, the DB password is changed. This means that all of the `tilesrv` containers restart, and any running ingestion job fails.

- If you reload the `vm` template, any running ingestion job is cancelled as the VMSS is scaled down.

## Testing that your deployment works

*To be provided*

## Switching over to your deployment

### Setting up Azure Front Door

To change over your deployment, perform the following steps.

- Go the Azure Front Door instance in the portal. All instructions are related to that resource.

- Select `Origin Groups` on the left panel, and create a new `Origin Group` (which is a place where traffic can end up). That group should have the following features.

    - Name it after your deployment. For example, the `p01` deployment can sensibly be named `p01-tilesrv`.

    - Single Origin within it, which should be your Azure Container App (select `Container App` as the title, and pick the container app URL from the list).

    - Allow HTTP health probes on the `/metrics` path.

    - Within the origin, do *not* enable subject name validation.

- Within the (single existing) endpoint, there should be two `route` instances, one for live traffic () and one for testing (`tst-soundscape`). First test your deployment by setting up the test configuration to point to your new deployment.

    - The matching pattern must be `/tiles/*`, with origin path `/` (so `/tiles` requests go to the root on the tile server app).

    - It should be enabled.

    - Compression and caching must be enabled, with the `Use query string` option.

    - The origin group should be the *production* origin group.

You now could in principle route traffic to your new deployment. We first point a test domain (`tst.soundscape.scottishtecharmy.org`) at the endpoint, then the real domains later.

*To be added - how do you cut a domain over?*

### Testing

Now we test. To validate that a domain is working, you should do the following.

- Pick a directory where you will run all your tests (and where all your outputs will go), and switch to it.

- From that directory, run the following command.

    ~~~bash
    for i in prd2 tst soundscape
    do
        nohup bash /ROOT_OF_REPO/scripts/loadtest.sh DOMAIN &
    done
    ~~~

    You can check the output log file in that directory (tail it - the command takes a long time) to make sure that no errors are being reported.

- You should see that all three domains are fine.

### Cutting over

Now you cut things over.

- Go to the test route, `tst-soundscape`, and change the origin group to the new origin group. This should not cause any traffic interruption in the `tst` domain; check the logs for a few minutes. You can also sanity check instantly with

    ~~~bash
    time curl -i https://tst.soundscape.scottishtecharmy.org/tiles/16/32127/21794.json
    ~~~

- If that works, cut the main route over, again ensuring that a running load test is not affected.

