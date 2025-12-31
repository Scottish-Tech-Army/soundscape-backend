# Deployment of the iOS backend in Azure

This document describes how to deploy a new deployment. It does not cover the global shared resources (which are assumed to exist).

The general model is as follows.

- A new Resource Group is created in Azure, containing a complete database, tile server application, and all the other components.

- After the new RG is created, the shared Front Door instance is cut over to point at it.

- Once sufficient testing has been done, the old RG can be deleted.

The process is as follows.

- Check some [prerequisites](#prerequisites)

- [Set up your deployment in Azure](#deploying-in-azure).

- [Test that it all works](#testing-that-your-deployment-works).

- [Cut over live traffic to your new deployment](#switching-over-to-your-deployment).

## Prerequisites

- General prerequisites are described in the [infrastructure deployment document](docs/infradeploy.md), and you should follow those, including in particular:

    - Making sure that the diags infrastructure has been deployed.

    - Making sure that quotas have been set.

- An alert rule should have been configured for incoming requests. This must have been created in the shared resource subscription, as follows.

    - Scoped to the share LAW

    - Using the following query

            AzureDiagnostics
                | where Category == "FrontDoorAccessLog"
                | where requestUri_s contains "/tiles"
                | where httpStatusCode_s != 200
                | project TimeGenerated, requestUri_s, userAgent_s, httpMethod_s, httpStatusCode_s, httpStatusDetails_s, clientCountry_s, errorInfo_s, timeTaken_s
                | order by TimeGenerated desc

    - Run once an hour, only allowed to fire once per day

    - Link to the alert group above

## Deploying in Azure

Follow the following steps. Note that some of the scripts here take quite some time to run - up to ten or fifteen minutes for the slower ones. Be patient, and let them complete.

- Set up a config file. Production instances should be named `iNN` where `NN` is a two digit number that should be monotonically increasing, such as `i01`.

    - The file should be in the [config](config) directory, and be named `ios-iNN.sh`

    - Contents should be as below; see comments.

        ~~~bash
        # Parameters in use
        export PREFIX=i05           # As described above
        export RG=ios05             # As described above
        export REGION=northeurope   # Region - normally should not change
        export VERSION=${PREFIX}    # Version of containers - make unique per deployment

        # Area to export - should be "planet" unless for testing (when "finland" is a reasonable choice)
        export AREA=planet

        # Globally unique names, used in both bicep and in scripts
        # A good way to generate this is "date | md5sum | head -c 20 && echo"
        export UNIQUESTRING=fe6971508913740178df   # Ensure globally unique

        # Subscription name
        export SUBSCRIPTION=b9ba9683-feef-47c8-bcc0-08e791dc1493
        ~~~

 - Source the config file.

    ~~~bash
    . config/ios_iNN.sh
    ~~~

- Ensure that you logged into Azure, and using the correct subscription.

    ~~~bash
    az login --use-device-code
    az account show
    ~~~

    If necessary, you can log in using a different account, or use `az account set` to reset which subscription is in use.

- Build and upload images. This creates container images of the specified version, and loads them into the shared repository.

    ~~~bash
    bash scripts/iosbuild.sh
    ~~~

- Run the base deploy script. This deploys the database, tile server apps, and much of the core infrastructure.

    ~~~bash
    bash scripts/iosbase.sh
    ~~~

    *Very occasionally this fails with an error reporting `PrincipalNotFound`. If this occurs, just rerun the command. This is an intermittent timing issue caused by a managed identity being assigned a role before Entra has propagated its creation, and is resolved when the command is rerun.*

- Run the VM deployment script. This deploys all the peripheral (but necessary) components, including ingestion tooling, function apps, and dashboards, then sets up an origin group to route traffic.

    ~~~bash
    bash scripts/iosvm.sh
    ~~~

- Deploy the function app code to the deployment.

    ~~~bash
    bash scripts/functionapp.sh
    ~~~

- Create an origin group linking back to the tile server app, so we can later route live traffic. *Warning - doing this on a live system can break Front Door traffic. It will recover within half an hour or so, but you don't want to do that with live traffic. The script will check and try to stop you doing this.*

    ~~~bash
    bash scripts/iosorigin.sh
    ~~~

- Clear out temporary build files. This is optional, but it avoids having random built artefacts lying around cluttering up the disk.

    ~~~bash
    bash scripts/cleanup.sh
    ~~~

### Redeploy gotchas

If you redeploy the various bicep templates, some bad things happen.

- If you reload the `deploy` template, the DB password is changed. This means that all of the `tilesrv` containers restart, and any running ingestion job fails (though this should be a short blip of a few seconds).

- If you reload the `vm` template, any running ingestion job is cancelled as the VMSS is scaled down. This is benign so long as you are not in the middle of a multi-hour ingestion run.

## Ingesting data and basic validation

### Triggering ingestion

Your deployment still does not work, because ingestion has not occurred. You can just wait until the weekly ingestion run happens, but a smarter idea is to kick it off manually.

- Open the [Azure portal](https://portal.azure.com).

- Find the resource group you just created (`iosNN`) and select it to view the list of resources in it.

- Click on the Azure Function app that triggers ingestion - this is the one starting `trigger-`.

- Click on the only function in the list, `ingest-timer`.

- In the `Code&Test` blade, click on `Test/Run`

- This will cause a new subwindow to open with a big `Run` button. Click it.

### Validating that your run has completed

The ingestion will take around 8-10 hours. To monitor its progress, check the dashboard and the ingestion logs as described in the [operations document](operations.md).

## Switching over to your deployment

Having followed this process, you should cut traffic over to the new backend instance, which can be done as follows.

### Setting up Azure Front Door

To change over your deployment, perform the following steps.

- Select the Azure Front Door instance (the only one, in the `soundscape-shared` resource group) in the portal. All instructions are related to that resource.

- Select `Origin Groups` on the left panel. You should see the origin group for your new instance there.

- The Front Door instance already has two live endpoints, one for live traffic `prd2` and one for test traffic `tst`. Within each of these there is a single route.

    - Click on `Front Door manager`

    - Click the `tst.soundscape.scottishtecharmy.org` endpoint.

    - Change the origin group to be the one for your new deployment.

- Double check that the traffic is working - for example, the following

    ~~~bash
    curl -i https://tst.soundscape.scottishtecharmy.org/tiles/16/32127/21794.json?nocache=1234
    ~~~

    where you can change the `nocache` number to ensure that caching does not happen.

### Testing

Now we test properly. To validate that the test domain (and so your deployment) is working, you should do the following.

- Pick a directory where you will run all your tests (and where all your outputs will go), and switch to it.

- From that directory, run the following command.

    ~~~bash
    nohup bash /ROOT_OF_REPO/scripts/loadtest.sh tst &
    ~~~

    (Note that we are testing the `tst` subdomain here, which points at your new deployment.)

- Check results.

    - There is an output log and a detailed CSV file of results that are being generated in your test directory. You can tail these, but you should not consider the test a success until it has fully completed.

    - You should see load arriving at your deployment.

    - Everything should just work (TM).

### Cutting over

Now it is time to cut the traffic over.

- Change to your directory.

- From that directory, run the following command.

    ~~~bash
    nohup bash /ROOT_OF_REPO/scripts/loadtest.sh prd2 &
    nohup bash /ROOT_OF_REPO/scripts/loadtest.sh soundscape &
    ~~~

    (Note that we are now testing the live domains.) Double check that the tests are running correctly from the logs. The dashboard should show traffic in Front Door Manager, but (initially) not in your deployment.

- While the test is running, cut over traffic.

    - Click on `Front Door manager`

    - Click the `fdr-appcontainer` endpoint.

    - Change the origin group to be the one for your new deployment.

- You are now live! Check that everything is working correctly.

    - All output logs should continue not to show any errors.

    - You should see load arriving at your deployment.

    - Everything should just work (TM).
