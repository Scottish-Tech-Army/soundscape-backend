# iOS Architecture

This repository contains code that allows the deployment of a back end for the [Soundscape iPhone app](https://apps.apple.com/gb/app/soundscape/id6459021379). The app calculates its location, converts that to OpenStreetMap tile format, and uses that to build an HTTP GET request that retrieves a JSON file of [OpenStreetMap](https://www.openstreetmap.org) data showing known locations in the area. The back end (this repository) constructs, stores, and returns that data.

![Architecture Diagram](soundscape.drawio.svg)

## Architecture summary

### Deployment instance resource group

Each deployed instance is in Azure, and contains the components below in a single resource group. Note that while there is normally only one such instance, a new one can be quickly created and cut over, to allow upgrades and code changes without risking an outage.

- The backend database is an [Azure Database for PostgreSQL](https://learn.microsoft.com/en-us/azure/postgresql/) instance, with the PostGIS extension installed.

- The actual web interface is served by the Tile Server [Azure Container App](https://learn.microsoft.com/en-us/azure/container-apps/overview), usually abreviated to `tilesrv`. This container app runs code that uses the `aiohttp` async web framework to provide a simple interface that queries the database. It expects a GET request in the `/z/x/y` format `/{zoom}/{x}/{y}.json`, where `zoom` must be 16. This app also has a `/metrics` interface which returns statistics about tiles served, errors, etc. and a `/probe/alive` interface to check if the service is up (though most metrics are actually passed through OpenTelemetry to Application Insights in practice).

- The database is populated by ingestion tooling consisting of a [VM Scale Set](https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/overview), triggered by an [Azure Function](https://learn.microsoft.com/en-us/azure/azure-functions/functions-overview). This is described in detail below.

- There are various logging and diagnostics tooling components from the Azure Monitor family including [Log Analytics](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-overview), and [Application Insights](https://learn.microsoft.com/en-us/azure/azure-monitor/app/app-insights-overview)

### Shared resource group

In addition to these per-instance components, there are some global components in a shared Resource Group. *The tooling in this repository does not cover creating this RG - it must already exist.*

- The entire thing is fronted by [Azure Front Door](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-overview), which allows traffic to be cut over from one back end instance to another, manages SSL termination, and provides CDN capability and some metrics.

- There is a common Azure Container Registry that stores the container images for the Tile Server.

- There are multiple DNS zones that allow incoming traffic to be routed to the platform, specifically the following.

    - `prd2.soundscape.scottishtecharmy.org`: live traffic from the app

    - `soundscape.scottishtecharmy.org`: live traffic from an older version of the app

    - `tst.soundscape.scottishtecharmy.org`: test traffic, used to test new back end deployment instances

## High level flow

The high level flow is shown in the architecture diagram above.

- The app requests a URL requesting a tile - something like

        https://prd2.soundscape.scottishtecharmy.org/tiles/16/18748/25072.json

- The request arrives at the [Azure Front Door](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-overview) instance. Front Door handles SSL termination for the domain, then forwards the request to the Tile Server Container App running in the deployment, changing the URL to

        https://TILESRV_DOMAIN/16/18748/25072.json

    Note that there is caching in Front Door - if the same request is received multiple times at the same POP, Front Door will return the cached value at this point.

- The Tile Server Container App receives the request, parses it, and builds the tile information from the database.

    - It builds tiles using the function `soundscape_tile` defined in `tilefunc.sql`.

    - That in turn relies on the bounding funtion `TileBBox` and various utility functions defined `postgis-vt-util.sql`.

## Ingestion

The data in the database is downloaded and ingested from public data at [Geofabrik](https://www.geofabrik.de). The process for this is as follows.

- There is a [VMSS](https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/overview) which is normally of size 0. When scaled up to size 1, the VM installs and runs the [imposm3](https://github.com/omniscale/imposm3) tooling which performs a full download of all the data. `imposm3`

  - downloads all the data as `pbf` files;

  - imports into a temporary Postgres namespace called `import`;

  - then atomically rotates the data into the live namespace when it completes.

    This entire process takes about ten hours for the entire globe.

- The VMSS scaling is managed as follows.

    - Normally it is zero - i.e. no VM is running. VMs are not cheap.

    - Once a week, a function app with a timer trigger increases the scale to 1, so a single VM is instantiated. This trigger can also be fired manually through the portal to force an update.

    - The VM when created installs and runs the ingestion jobs through cloud init. If the run is successful, the ingestion job scales the VMSS down again, and the VM disappears.

# Android architecture

There are three components to the Android architecture.

1. There is a tileserver component that serves up tiles based on a protomap format, running in Cloudflare (but orchestrated from Azure).

2. There is an offline maps download component that again runs in Cloudflare, orchestrated from Azure.

3. There is a search component. This is not contained in this repository at all.