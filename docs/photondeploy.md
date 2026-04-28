# Photon server support

## Design

The basic model is that the photon server runs on a VM in a VMSS. When the VM is first created, it downloads all the software it needs and builds a full photon database, with a load balancer IP in front of it, accessible only from Front Door.

## Prerequisites

- General prerequisites are described in the [infrastructure deployment document](/docs/infradeploy.md), and you should follow those, including in particular:

    - Making sure that the diags infrastructure has been deployed.

    - Making sure that the shared infrastructure (`soundscape-shared` RG, `soundscape-fd` Front Door, and the Azure Container Registry) has been deployed.

    - Making sure that the `photon` and `photontest` DNS zones and Front Door endpoints have been added (see [Adding DNS zones and endpoints](/docs/infradeploy.md#adding-dns-zones-and-endpoints)).

    - Making sure that quotas have been set.

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

Once the new VM is healthy, cut traffic over to the new backend instance by following the [Front Door cutover pattern](/docs/infradeploy.md#front-door-cutover-pattern) with the following values:

- `<TEST_ENDPOINT>` = `photontest`
- `<PROD_ENDPOINT>` = `photon`
- `<SMOKE_URL>` = `https://photontest.soundscape.scottishtecharmy.org/photon/api?q=harbour&nocache=1234`
- `<LOADTEST_CMD>` = `bash /ROOT_OF_REPO/scripts/photonloadtest.sh`

