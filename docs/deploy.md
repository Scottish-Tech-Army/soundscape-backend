# Deployment and management

This document describes how to deploy a new deployment. It does not cover the global shared resources (which are assumed to exist).

## Prerequisites

Before you can initially create a deployment, you need the following.

- A PC to run the tooling on. The tooling was tested using Linux, but anything running bash should be fine, including a Mac or WSL on Windows. This PC must have various utilities installed . These include the following.

    - [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)

    - [Docker](https://docs.docker.com/engine/install/)

    - Various scripts contained in this repo, which must be checked out.

- An Azure subscription. This will contain the various components that get deployed.

## Setting up resources in Azure

Follow the following steps.

- Set up a config file. *TODO: document with an example.*

    Before running any of the bash commands, you should source this config file.

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

## Testing that your deployment works

*To be provided*

## Switching over to your deployment

*To be provided - change front door*