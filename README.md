# Soundscape Backend

This repository contains code for the backend services for the Soundscape iPhone app running in Azure. It is structured as follows.

The repository is structured as follows.

- [docs](docs) contains documentation. Please read it, or the author will be sad.

    - [Architecture](docs/architecture.md)

    - [How to deploy the system](docs/deploy.md)

    - [Operations processes](docs/operations.md) such as debugging and testing deployments

- [scripts](scripts) contains scripts that allow you to deploy the solution, using all of the compenents below.

- [config](config) contains configuration files that specify parameters for each deployment.

- [templates](templates) contains deployment templates (largely consisting of Azure Bicep).

- [src](src) contains code.

    - [ingest](src/ingest) contains ingestion tooling to load the database.

    - [tilesrv](src/tilesrv) contains the tile serving app.

    - [trigger](src/trigger) contains code for the Azure function that triggers periodic updates.

    - [debug](src/debug) contains a Dockerfile for a debug container. It is not used, but kept around for future use.

    - [ingest_diffs](src/ingest_diffs) contains an ingestion diffs container. This is no longer used (as it is simpler and cheaper to perform full ingestions every week than to run it continuously), but in principle it may be reinstated in future.

