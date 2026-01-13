# Soundscape Backend

This repository contains code for the backend services for the Soundscape app running in Azure. It is concerned with both iOS and Android apps.

The repository is structured as follows.

- [docs](docs) contains documentation. Please read it, or the author will be sad.

    - [Architecture](/docs/architecture.md) describes the architecture.

    - [Infrastructure deployment](/docs/infradeploy.md) explains how to deploy common infrastructure, required for other components. This is more a record of what was done that anything that you are likely to need day to day, but it does document tools that you might need in order to run any of the deployment steps.

    - If you want to deploy a new iOS backend RG and cut over traffic, read the [iOS backend instructions](/docs/iosdeploy.md)

    - If you want to deploy a new Android backend RG and cut over traffic, read the [Android backend instructions](/docs/androiddeploy.md)

    - [Photon server docs](/docs/photon.md) describe how to run a photon search server. *This is a work in progress, and should not be used until it is fully tested.*

    - [Operations processes](/docs/operations.md) describes how to operate an existing deployment, including how to use search queries, analyse logs, and monitor load.

- [scripts](scripts) contains scripts that allow you to deploy the solution, using all of the components below.

- [config](config) contains configuration files that specify parameters for each deployment.

- [templates](templates) contains deployment templates (largely consisting of Azure Bicep).

- [src](src) contains code for various purposes

    - For the iOS backend:

        - [ingest](src/ingest) contains ingestion tooling that runs in a VM to load the database.

        - [tilesrv](src/tilesrv) contains the tile serving app that serves up tiles from the database.

        - [ingest_diffs](src/ingest_diffs) contains an ingestion diffs container. This is no longer used (as it is simpler and cheaper to perform full ingestions every week than to run it continuously), but in principle it may be reinstated in future.

        - [debug](src/debug) contains a Dockerfile for a debug container. It is not used, but kept around for future use.

    - For the Android backend:

        - [pmtiles](src/pmtiles) contains tooling that runs in the Android pmtiles VM to download data and set it up in the Cloudflare account.

        - [photon](src/photon) contains tooling for the photon server, which provides a search server.

    - For both Android and iOS:

        - [trigger](src/trigger) contains code for the Azure function that periodically (or on demand manually) triggers a new VM to be created to redownload and prepare an updated set of data.

        - [vmcount](src/vmcount) contains code for the Azure function that counts the number of active VMs, used purely because this allows dashboard to graph it.

        - [vmutils](src/vmutils) contains common VM utility code.

## Third party software

This code contains third party software from the [protomaps PMTiles repository](https://github.com/protomaps/PMTiles), which is licensed according to [its own license](thirdparty/pmtiles/LICENSE) - see [the README](https://github.com/protomaps/README.md) for further information.
