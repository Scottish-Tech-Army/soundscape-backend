# Soundscape Backend

This repository contains code for the backend services for the Soundscape app running in Azure. It is concerned with both iOS and Android apps.

The repository is structured as follows.

- [docs](docs) contains documentation. Please read it, or the author will be sad.

    - [Architecture](docs/architecture.md)

    - [How to deploy an iOS backend](docs/iosdeploy.md)

    - [How to deploy an Android backend](docs/androiddeploy.md)

    - [Operations processes](docs/operations.md) such as debugging and testing deployments. *This is iOS only for now; TBD if it will be extended or another document created.*

- [scripts](scripts) contains scripts that allow you to deploy the solution, using all of the components below.

- [config](config) contains configuration files that specify parameters for each deployment.

- [templates](templates) contains deployment templates (largely consisting of Azure Bicep).

- [src](src) contains code.

    - [ingest](src/ingest) contains ingestion tooling to load the database.

    - [tilesrv](src/tilesrv) contains the tile serving app.

    - [trigger](src/trigger) contains code for the Azure function that periodically (or on demand manually) triggers a new VM to be created to fully ingest a new set of data and apply it to the database.

    - [vmcount](src/vmcount) contains code for the Azure function that counts the number of active VMs, used purely because this allows the dashboard to show it.

    - [debug](src/debug) contains a Dockerfile for a debug container. It is not used, but kept around for future use.

    - [ingest_diffs](src/ingest_diffs) contains an ingestion diffs container. This is no longer used (as it is simpler and cheaper to perform full ingestions every week than to run it continuously), but in principle it may be reinstated in future.

## Third party software

This code contains third party software from the [protomaps PMTiles repository](https://github.com/protomaps/PMTiles), which is licensed according to [its own license](thirdparty/pmtiles/LICENSE) - see [the README](https://github.com/protomaps/README.md) for further information.
