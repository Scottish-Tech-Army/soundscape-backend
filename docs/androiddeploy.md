# Deployment of the Android backend in Azure

This document describes how to deploy a new Android deployment. Note that there is no manual cutover process; triggering a creation of a new VM in the VMSS will automatically validate the downloaded data and change the Cloudflare configuration to use the new deployment. If you are replacing a deployment, disable the VMSS in it (or Cloudflare will flap between deployment instances, which is benign but wasteful).

## Prerequisites

Before you can initially create a deployment, you need the following.

- General prerequisites are described in the [infrastructure deployment document](/docs/infradeploy.md), and you should follow those, including in particular:

    - Making sure that the diags infrastructure has been deployed.

    - Making sure that quotas have been set.

- Access to the Cloudflare account. Using this you must

    - [Set up Cloudflare configuration](#cloudflare-configuration)

    - [Configure some Cloudflare secrets](#cloudflare-secrets)

### Cloudflare configuration

Configure Cloudflare.

- Log into the [Cloudflare dashboard](https://dash.cloudflare.com/)

- Click on `R2 object storage` on the left.

- Enable R2 if it is not already enabled.

Find your Cloudflare DNS domain.

- Log into the [Cloudflare dashboard](https://dash.cloudflare.com/)

- Click on `Compute (Workers)` on the left panel to expand it.

- Click on `Workers and Pages` under `Compute (Workers)`.

- You may or may not have workers.

    - If you have no workers, I apologise for the sheer awfulness of this workflow. Just go with it.

        - Click the "Get Started with Hello World" button.

        - After doing so, you will see a URL. The domain you want is of form `blah.workers.dev`, i.e. the last three words in the string.

        - Delete the worker. You do not need it any more.

    - Otherwise go to your workers, and pick a worker, to again find the domain you want.

        The URL receiving production data should then be `https://workername.blah.workers.dev` where you found what `blah` should be above, and `workername` is the name of the worker in question.

### Cloudflare secrets

Get secrets from Cloudflare and store them for later storage in a key vault.

- Log into the [Cloudflare dashboard](https://dash.cloudflare.com/)

- Find your Account ID.

    - Select `Account Home` on the left hand panel.

    - Select the three dots to the right of the account name, and click on `Copy account ID`.

- Create an API token to deploy resources. (This assumes that you are using an account API token; you can also use a user API token, but then when you leave the organisation it will all stop working.)

    - Select `Account Home` on the left hand panel.

    - Select the three dots to the right of the account name, and click on `Account API Tokens`.

    - Click on `Create Token`

    - Use the `Edit Cloudflare Workers` option to create the token

    - Store off the API key.

- Find your Cloudflare subdomain - the string after the worker name in the URL to access a worker in the account. This was described above.

- Create R2 access credentials. (This could use the same overpowered API token above, but we instead use a dedicated token.)

    - In the left hand pane, select `Storage and databases`, then `R2 Object Storage`, then `Overview`.

    - In the `Account details` section of the page, there is a button called `API tokens`.

    - That will give you a button called create API tokens that lets you create the right kind of API token. Select `Object Read and Write`.

    - Store off both the Access Key and the Secret.

## Deploying in Azure

Follow the following steps. Note that some of the scripts here take quite some time to run - up to ten or fifteen minutes for the slower ones. Be patient, and let them complete.

- Set up a config file. Android instances should be named `aNN` where `NN` is a two digit number that should be monotonically increasing, such as `a01`.

    - The file should be in the [config](config) directory, and be named `android-aNN.sh`

    - Contents should be as below; see comments.

        ~~~bash
        # Parameters in use
        export PREFIX=a03           # As described above
        export RG=android03         # Same number as above
        export REGION=westeurope    # Region - normally should not change

        # Whether to use spot VMs; not permitted in some subscriptions
        export USE_SPOT=false

        # Globally unique names, used in both bicep and in scripts
        # A good way to generate this is "date | md5sum | head -c 20 && echo"
        export UNIQUESTRING=fe6971508913740178df   # Ensure globally unique

        # Area to use - should normally be "monaco" (for fast low level testing) or "planet"
        export AREA=planet

        # Debug mode, which largely means "allow ssh debug access"
        export DEBUG=true

        # Names of export and tiles storage buckets; "extracts" and "pmtiles" for live traffic
        export EXPORTS_BUCKET=extracts
        export PMTILES_BUCKET=pmtiles

        # Subscription ID
        export SUBSCRIPTION=9ff2d6b4-099b-4370-9629-6f490b4ac356
        ~~~

        Some of these deserve more comment.

        - `REGION` can be any valid Azure region, but there can be performance implications for picking one that is too far from the R2 deployment location.

        - `UNIQUESTRING` is just that - a unique string for this deployment used (for example) in storage account names.

        - `EXPORTS_BUCKET` and `PMTILES_BUCKET` are the names of the R2 buckets storing exports and the main pmtiles file. These values are also part of the URL from which data is downloaded. The reason these are not just hardcoded is that this allows the construction of test deployments that do not clash with the production one.

 - Source the config file.

    ~~~bash
    . config/android-aNN.sh
    ~~~

- Run the base deploy script.

    ~~~bash
    bash scripts/androidbase.sh
    ~~~

- Set up parameters in key vault using [the portal](https://portal.azure.com).

    - Go to the resource group you just created.

    - Click on the key vault.

    - Add secrets as follows. These are case sensitive; how to obtain the values is detailed above.

        `cloudflare-account-id :` The Account ID for Cloudflare

        `cloudflare-api-token  :` The API token for Cloudflare

        `cloudflare-subdomain  :` The subdomain for Cloudflare

        `r2-access-key         :` The R2 access key

        `r2-secret             :` The R2 secret

- Deploy the VM scale set.

    ~~~bash
    bash scripts/androidvm.sh
    ~~~

- Deploy the function app code to the deployment.

    ~~~bash
    bash scripts/functionapp.sh
    ~~~

- Clear out temporary build files. This is optional, but it avoids having random built artefacts lying around cluttering up the disk.

    ~~~bash
    bash scripts/cleanup.sh
    ~~~

- The deployment is now running, but it has not downloaded any data yet. It will do this periodically on a timer, but to make it do immediately so you should do the following.

    - Open the [Azure portal](https://portal.azure.com).

    - Find the resource group you just created (`androidNN`) and select it to view the list of resources in it.

    - Click on the Azure Function app that triggers ingestion - this is the one starting `trigger-`.

    - Click on the only function in the list, `ingest-timer`.

    - In the `Code&Test` blade, click on `Test/Run`

    - This will cause a new subwindow to open with a big `Run` button. Click it.

- Monitor the progress of the operations following the [operations instructions](/docs/operations.md).
