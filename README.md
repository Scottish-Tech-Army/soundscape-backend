# Soundscape Backend

This repository contains code for the backend services for the [Soundscape app](https://scottish-tech-army.github.io/Soundscape-Android/) running in Azure. It is concerned with both iOS and Android apps.

Soundscape is a navigation and audio app for blind and visually impaired users; this repository contains only the Azure backend that serves it. It is intended for people deploying or operating that backend, not for app developers.

The repository is structured as follows.

- [docs](docs) contains documentation. Read these documents before deploying or modifying any component.

    - [Architecture](/docs/architecture.md) describes the architecture.

    - [Infrastructure deployment](/docs/infradeploy.md) explains how to deploy common infrastructure, required for other components. This is more a record of what was done than anything that you are likely to need day to day, but it does document tools that you might need in order to run any of the deployment steps.

    - If you want to deploy a new iOS backend RG and cut over traffic, read the [iOS backend instructions](/docs/iosdeploy.md)

    - If you want to deploy a new Android backend RG and cut over traffic, read the [Android backend instructions](/docs/androiddeploy.md)

    - If you want to deploy a new Photon server instance and cut over traffic, read the [Photon server instructions](/docs/photondeploy.md).

    - [Links site deployment](/docs/linksdeploy.md) documents how to deploy the Android App Links site (one-off; not normally re-run after initial deployment).

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

        - [cfmetrics](src/cfmetrics) contains code for an Azure function that periodically queries the Cloudflare GraphQL API to collect worker invocation and R2 bucket metrics, and writes them to Application Insights for dashboarding.

    - For the photon server:

        - [photon](src/photon) contains tooling for the photon server, which provides a search server (used by Android clients but logically distinct from the rest of the Android backend).

    - For the links site:

        - [links](src/links) contains the static files served by the links site (`assetlinks.json`, `apple-app-site-association`, `health`).

    - For both Android and iOS:

        - [trigger](src/trigger) contains code for the Azure function that periodically (or on demand manually) triggers a new VM to be created to redownload and prepare an updated set of data.

        - [vmcount](src/vmcount) contains code for the Azure function that counts the number of active VMs, used purely because this allows dashboard to graph it.

        - [usagemetrics](src/usagemetrics) contains code for the Azure function that collects long-term usage metrics (iOS/photon request and session counts, pmtiles and offline-map downloads) into the shared metrics PostgreSQL database for Superset. The one codebase is deployed twice — a shared reader of the Front Door logs and a per-instance Android reader of the Cloudflare `cfmetrics` traces — selected by the `METRICS_SOURCE` app setting.

        - [vmutils](src/vmutils) contains common VM utility code.

## Third party software

This code contains third party software from the [protomaps PMTiles repository](https://github.com/protomaps/PMTiles), which is licensed according to [its own license](thirdparty/pmtiles/LICENSE) - see [the README of that repo](https://github.com/protomaps/PMTiles) for further information.
