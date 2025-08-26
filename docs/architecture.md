# Architecture

This repository contains code that allows the deployment of a back end for the [Soundscape iPhone app](https://apps.apple.com/gb/app/soundscape/id6459021379). In terms of interface, the app calculates its location, and issues a GET request to a URL that passes in the zoom level (which must be 16), and the `x` and `y` coordinates. This retrieves a JSON file of [OpenStreetMap](https://www.openstreetmap.org) data showing known locations in the area.

**TODO: provide architecture diagram**

## Architecture summary

The deployment exists in Azure, and contains the following components.

- The backend database is an [Azure Database for PostgreSQL](https://learn.microsoft.com/en-us/azure/postgresql/) instance, with the PostGIS extension installed.

- The data in the database is downloaded from public data at [Geofabrik](https://www.geofabrik.de). The process for this is as follows.

    - There is a [VMSS](https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/overview) which is normally of size 0. When scaled up to size 1, the VM installs and runs the [imposm3](https://github.com/omniscale/imposm3) tooling which performs a full download of all the data. `imposm3` downloads all the data as `pbf` files; imports into a temporary Postgres namespace called `import`; then atomically rotates the data into the live namespace when it completes. This entire process takes about six hours for the covered regions (most of Europe and North America, Australia and New Zealand, Japan, and a couple of other countries).

    - The VMSS scaling is managed as follows.

        - Normally it is zero - i.e. no VM is running. VMs are not cheap.

        - Once a week, a function app with a timer trigger increases the scale to 1, so a single VM is instantiated. This trigger can also be fired manually through the portal to force an update, or an administrator can just change the VMSS settings through the portal or command line.

        - The VM when created installs and runs the ingestion jobs through cloud init. If the run is successful, the import job scales the VMSS down again, and the VM disappears.

- The actual web interface is served by an [Azure Container App](https://learn.microsoft.com/en-us/azure/container-apps/overview), called `tilesrv`. This container app runs code that uses the `aiohttp` async web framework to provide a simple interface that queries the database. It expects a GET request in the `/z/x/y` format discussed above `/{zoom}/{x}/{y}.json`. It also has a `/metrics` interface which returns statistics about tiles served, errors, etc. and a `/probe/alive` interface to check if the service is up (though most metrics are actually passed through OpenTelemetry to Application Insights in practice).


- There are various logging and diagnostics tooling components from the Azure Monitor family including [Log Analytics](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/log-analytics-overview), and [Application Insights](https://learn.microsoft.com/en-us/azure/azure-monitor/app/app-insights-overview)

- In addition to these per-instance components, there are some global components.

    - The entire thing is fronted by [Azure Front Door](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-overview), which allows traffic to be cut over from one deployment to another, and provides CDN capability and some metrics.

    - There is a common Azure Container Registry that stores the various container images.

    - There are multiple DNS zones that allow incoming traffic to be routed to the platform.

## Technical details

**TODO: provide some more information, including the notes below.**

### DNS domains

**TODO: describe DNS domains etc.**

### Tilesrv API

**TODO: write up a bit more.**

The service only supports zoom level 16. You will be able to perform a quick test that it is working by using a browser/curl/whatever to hit the Tile service which is listening on 8080 and it should respond with a GeoJSON file for the Washington Capitol Building:

https://DOMAIN_NAME/16/18748/25072.json

The request above is in the format: /zoom-level/x-coordinates/y-coordinates.json. The service currently only supports zoom level 16.

### Database info

The data is all stored in a database called `osm`. Within that there are three schemas.

**TODO: check this. I think these schema names are wrong; import is correct, but production and backup are not**

1. `import`
2. `production`
3. `backup`

Each schema contains of three tables.

1. `osm_entrances`
2. `osm_places`
3. `osm_roads`

The tile service relies on database functions that are created by the ingestion process running some SQL scripts.

- It builds tiles using the function `soundscape_tile` defined in `tilefunc.sql`.

- That in turn relies on the bounding funtion `TileBBox` and various utility functions defined `postgis-vt-util.sql`.



