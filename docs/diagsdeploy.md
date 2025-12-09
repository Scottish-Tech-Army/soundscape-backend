# Diagnostics deployment

This document describes how to deploy shared diagnostics tooling before you can deploy individual instances. These are stored in a shared resource group, with both iOS and Android resources present in it.

To do this, follow the steps below.

- Set up a config file.

    - The file should be in the [config](config) directory, and be named `diags-cfg.sh`

    - Contents should be as below; see comments.

        ~~~bash
        # Diags configuration
        # This covers purely the tooling that deploys diags queries for both Android and iOS.
        # Region and RG
        export DIAGSREGION=westeurope
        export DIAGSRG=soundscape-diags

        # Do not change from here down
        # This subscription stuff is purely to make sure we are using the right Azure subscription.
        export SUBSCRIPTION=4bf1580a-f73d-4821-8cdc-605925ba78e9
        ~~~

 - Source the config file.

    ~~~bash
    . config/diags-cfg.sh
    ~~~

- Ensure that you logged into Azure, and using the correct subscription.

    ~~~bash
    az login --use-device-code
    az account show
    ~~~

    If necessary, you can log in using a different account, or use `az account set` to reset which subscription is in use.

- Load the shared queries for Android.

    ~~~bash
    bash scripts/androiddiags.sh
    ~~~

- Load the shared queries for iOS.

    ~~~bash
    bash scripts/iosdiags.sh
    ~~~

- Set up the alert group that will handle all alerts. This is done through the portal so that we do not need to check in people's email addresses in git repositories.

    - Go to the [Azure portal](https://portal.azure.com).

    - Find `alerts`, either through the search bar or the list of `All services`.

    - Create an `Action group`, which will allow for the configuration of all alert destinations. Fill in the fields as follows.

        - Name: "soundscape"

        - Display name: "Soundscape"

        - Region: "global"

        - Email notifications, with the more modern unified format, and your email of choice to receive the mails.

        *FIXME: This action group has its ID hard coded in a couple of places; that should be tidied up when resources are moved to a shared subscription.*








