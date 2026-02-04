# Photon server support

*This is a work in progress; it is being checked in because it is easier to manage that way. It is independent of the standard Android and iOS deployments.*

## Design

The basic model is that the photon server runs on a VM in a VMSS. When the VM is first created, it downloads all the software it needs and builds a full photon database, with a load balancer IP in front of it, accessible only from Front Door.

## Instructions

Deployment of the photon server works as follows.

- Set up a config file. Photon instances should be named `pNN` where `NN` is a two digit number that should be monotonically increasing, such as `p01`.

    - The file should be in the [config](config) directory, and be named `photon-pNN.sh`

    - Contents should be as below; see comments.

        ~~~bash
        # Parameters in use
        export PREFIX=p01          # Prefix as above
        export RG=photon01         # Same number as above
        export REGION=westeurope   # Do not change region
        export VERSION=v1.0        # Version used to tag photon container

        # Globally unique string, used in both bicep and in scripts
        # A good way to generate this is "date | md5sum | head -c 20 && echo"
        export UNIQUESTRING=029edfef73100f3c0334

        # Area to use - should normally be "monaco" (for fast low level testing) or "planet"
        export AREA=planet

        # Subscription to use.
        export SUBSCRIPTION=9ff2d6b4-099b-4370-9629-6f490b4ac356
        ~~~

        Some of these deserve more comment.

        - `REGION` can be any valid Azure region.

        - `UNIQUESTRING` is just that - a unique string for this deployment used (for example) in storage account names.

- Source the config file

    ~~~bash
    . config/photon-p01.sh
    ~~~

- Upload the docker image.

    ~~~bash
    bash scripts/photonbuild.sh
    ~~~

- Load the base infrastructure

    ~~~bash
    bash scripts/photonbase.sh
    ~~~

- Set up the VMSS

    ~~~bash
    bash scripts/photonvm.sh
    ~~~

- Deploy the function app code to the deployment.

    ~~~bash
    bash scripts/functionapp.sh
    ~~~

- Create an origin group linking back to the photon instance, so we can later route live traffic. *Warning - doing this when the deployment you are working on is already live can break Front Door traffic. It will recover within half an hour or so, but you don't want to do that with live traffic. The script will check and try to stop you doing this.*

    ~~~bash
    bash scripts/photonorigin.sh
    ~~~

- Clear out temporary build files. This is optional, but it avoids having random built artefacts lying around cluttering up the disk.

    ~~~bash
    bash scripts/cleanup.sh
    ~~~

- The deployment is now running, but it has not yet completed downloading data. Check the dashboard for the RG (as in the [operations instructions](/docs/operations.md)) to see whether it has managed to become healthy yet.

## Switching over to your deployment

Having followed this process, you should cut traffic over to the new backend instance, which can be done as follows.

### Setting up Azure Front Door

To change over your deployment, perform the following steps.

- Select the Azure Front Door instance (the only one, in the `soundscape-shared` resource group) in the portal. All instructions are related to that resource.

- Select `Origin Groups` on the left panel. You should see the origin group for your new instance there.

- The Front Door instance already has two live endpoints, one for live traffic `photon` and one for test traffic `photontst`. Within each of these there is a single route that you must change.

    - Click on `Front Door manager`

    - Click the `photontst.soundscape.scottishtecharmy.org` endpoint.

    - Click on the route.

    - Change the origin group to be the one for your new deployment.

- Double check that the traffic is working - for example, the following

    ~~~bash
    curl -i "https://photontst.soundscape.scottishtecharmy.org/photon/api?q=harbour&nocache=1234"
    ~~~

    where you can change the `nocache` number to ensure that caching does not happen.

### Testing

*FIXME: To be provided - some kind of better test process.*

### Cutting over

Now it is time to cut the traffic over.

- Change to your directory.

- From that directory, run the following command. *FIXME: To be provided - some kind of better test process.*

    ~~~bash
    nohup bash /ROOT_OF_REPO/scripts/loadtest.sh prd2 &
    ~~~

    (Note that we are now testing the live domains.) Double check that the tests are running correctly from the logs. The dashboard should show traffic in Front Door Manager, but (initially) not in your deployment.

- While the test is running, cut over traffic.

    - Click on `Front Door manager`

    - Click the `photon.soundscape.scottishtecharmy.org` endpoint.

    - Change the origin group to be the one for your new deployment.

- You are now live! Check that everything is working correctly.

    - All output logs should continue not to show any errors.

    - You should see load arriving at your deployment.

    - Everything should just work (TM).

