# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Generate tiles based on OSM data previously injected into PostGIS
#
#
# Tiles are produced in a canonical form to ensure that'from scratch'
# generation of tiles will produce identical tiles given identical
# input.  Canonialization also makes tiles diffable.
#

import os
import math
import time
from datetime import datetime
import datetime as dt

import json
from collections import namedtuple
import argparse
import logging

import aiopg
import psycopg2
from psycopg2.extras import NamedTupleCursor
from psycopg2.extensions import make_dsn

from aiohttp import web

# Metrics imports
from opentelemetry.sdk.resources import Resource
from opentelemetry import metrics as otel_metrics
from opentelemetry import trace as otel_trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.instrumentation.aiohttp_server import AioHttpServerInstrumentor
from azure.monitor.opentelemetry.exporter import (
    AzureMonitorTraceExporter,
    AzureMonitorMetricExporter,
)

class StatCounter(object):
    def __init__(self, name, help):
        self.name = name
        self.help = help
        self.value = 0

    def inc(self):
        self.value += 1

    def report(self):
        f = '# HELP {name} {help}\n# TYPE {name} counter\n{name} {value}\n'
        s = f.format(name=self.name, help=self.help, value=self.value)
        return s

class StatHistogram(object):
    def __init__(self, name, help, interval, bucket_count):
        self.name = name
        self.help = help
        self.sum = 0
        self.interval = interval
        self.buckets = [0] * bucket_count
        self.count = 0
        self.bucket_count = bucket_count
        self.max_value = bucket_count * interval

    def sample(self, value):
        self.count += 1
        self.sum += value
        if value <= self.max_value:
            index = math.trunc(value / self.interval)
            if index * self.interval == value:
                index -= 1
            self.buckets[index] += 1

    def report(self):
        header = '# HELP {0} {1}\n# TYPE {0} histogram\n'.format(self.name, self.help)
        bucket_f = '{0}_bucket{{le="{1}"}} {2}\n'
        buckets = ''.join([bucket_f.format(self.name, (i+1)*self.interval, self.buckets[i]) for i in range(0, self.bucket_count)])
        total = bucket_f.format(self.name, '+Inf', self.count)
        sum = '{0}_sum {1}\n'.format(self.name, self.sum)
        count = '{0}_count {1}\n'.format(self.name, self.count)
        return ''.join([header, buckets, total, sum, count])

tilesrv_metrics_scraped = StatCounter('tilesrv_metrics_scraped', 'count of times scraped')
tilesrv_aliveprobe = StatCounter('tilesrv_aliveprobe_count', 'count of times probe for aliveness')
tilesrv_start = StatCounter('tilesrv_start_count', 'count of times tile server started')
tile_served = StatCounter('tile_served_count', 'count of tiles served')
tile_exception = StatCounter('tile_exception_count', 'count of tiles requests that ended in exception')
tile_queryfail = StatCounter('tile_queryfail_count', 'count of tiles requests that experienced query failure')

tile_querytime = StatHistogram('tile_querytime_seconds', 'histogram of tile query performance', 0.20, 20)
tile_size = StatHistogram('tile_size', 'histogram of tile size', 1024 * 8, 32)

# Metrics
#  - scrapes - counter
#  - tile_served - counter
#  - tile exception - counter
#  - tile error - counter
#  - tile good - counter
#  - tile good empty - counter
#  - alive queries - counter
#  - python memory usage - guage
#  - request time - histogram or summary

metrics = [
    tilesrv_metrics_scraped,
    tilesrv_aliveprobe,
    tilesrv_start,
    tile_served,
    tile_exception,
    tile_queryfail,
    tile_querytime,
    tile_size
]

TileGen = namedtuple('tilegen', 'count generator')
TileResult = namedtuple('tileresult', 'cost zoom x y data')
TileCloudStat = namedtuple('tilecloud', 'generated uploaded cost upload_cost')

zoom_default = 16
connection_pooling = True

tile_query = """
    SELECT * from soundscape_tile(%(zoom)s, %(tile_x)s, %(tile_y)s)
"""

# Set timeout to 15 seconds, necessary for some urban areas with dense infrastructure
timeout_set = "set statement_timeout=15000"

def tile_name(zoom, x, y,):
    return '{0}/{1}/{2}.json'.format(zoom, x, y)

async def gentile_async(cursor, zoom, x, y, gather_metrics=False):
    """
    Asynchronously generates a GeoJSON tile for the specified zoom level and tile coordinates.

    Args:
        cursor: An asynchronous database cursor for executing queries.
        zoom (int): The zoom level of the tile (must be 16).
        x (int): The x coordinate of the tile.
        y (int): The y coordinate of the tile.
        gather_metrics (bool, optional): If True, collects query execution time and tile size metrics. Defaults to False.

    Returns:
        str: A JSON string representing the GeoJSON FeatureCollection for the requested tile.

    Raises:
        psycopg2.Error: If a database error occurs during query execution.
    """
    try:
        if gather_metrics:
            query_start = time.perf_counter()
        await cursor.execute(timeout_set)
        await cursor.execute(tile_query, {'zoom': int(zoom), 'tile_x': x, 'tile_y': y})
        value = await cursor.fetchall()
        if gather_metrics:
            query_end = time.perf_counter()
            tile_querytime.sample(query_end - query_start)
        obj = {}
        obj['type'] = 'FeatureCollection'
        obj = {
            'type': 'FeatureCollection',
            'features': list(map(lambda x: x._asdict(), value))
        }
        tile = json.dumps(obj, sort_keys=True)
        if gather_metrics:
            tile_size.sample(len(tile))
        return tile
    except psycopg2.Error as e:
        logger.warning(f"Database error: {e}")
        raise

async def tile_handler_on_conn(conn, request):
    """
    Handles a tile request using an existing asynchronous database connection.

    This function processes incoming HTTP requests for map tiles, validates the zoom level,
    retrieves tile data from the database, and returns the result as a JSON response.
    It also updates relevant metrics for served and failed tile requests.

    Args:
        conn: An open asynchronous database connection.
        request: The incoming HTTP request containing tile parameters (zoom, x, y).

    Raises:
        web.HTTPNotFound: If the requested zoom level does not match the default.
        web.HTTPServiceUnavailable: If no tile data is found for the given parameters.

    Returns:
        web.Response: An HTTP response containing the tile data in JSON format.
    """
    start = datetime.now(dt.timezone.utc)
    async with conn.cursor(cursor_factory=NamedTupleCursor) as cursor:
        zoom = request.match_info['zoom']
        if int(zoom) != zoom_default:
            raise web.HTTPNotFound()
        x = int(request.match_info['x'])
        y = int(request.match_info['y'])
        tile_data = await gentile_async(cursor, zoom, x, y, True)
        if tile_data == None:
            logger.info("No data found %d/%d/%d", zoom, x, y)
            tile_queryfail.inc()
            raise web.HTTPServiceUnavailable()
        else:
            tile_served.inc()
            end = datetime.now(dt.timezone.utc)
            return web.Response(text=tile_data, content_type='application/json')

async def tile_handler_no_pooling(request):
    """
    Creates a new database connection to handle a tile request. It is used when connection pooling is not enabled.
    Handles a tile request by creating a new database connection without using connection pooling.

    This asynchronous handler establishes a fresh database connection for each incoming tile request,
    delegates the request processing to `tile_handler_on_conn`, logs the response status, and manages
    exceptions by incrementing the `tile_exception` metric.

    Args:
        request: The incoming HTTP request object containing application context and parameters.

    Returns:
        The HTTP response generated by `tile_handler_on_conn`.

    Raises:
        Exception: Propagates any exception encountered during request handling after incrementing the
        `tile_exception` metric.
    """
    try:
        async with aiopg.connect(request.app['dsn']) as conn:
            response = await tile_handler_on_conn(conn, request)
            logger.info("Response status code: %d", response.status)
            return response
    except Exception:
        tile_exception.inc()
        raise

async def tile_handler_pooling(request):
    """
    Handles a tile request using a pooled database connection (when pooling is enabled).

    This asynchronous handler acquires a connection from the application's connection pool,
    processes the tile request, logs pool statistics, and returns the tile data as an HTTP response.
    Increments the tile_exception metric and logs a warning if an exception occurs.

    Args:
        request: The incoming HTTP request containing tile parameters.

    Returns:
        web.Response: An HTTP response containing the requested tile data in JSON format.

    Raises:
        Exception: Propagates any exception encountered during request handling.
    """
    logger.info('Tile handler pooling called %s %s', request.method, request.url)
    try:
        async with request.app['pool'].acquire() as conn:
            logger.info('Pool: {0}/{1}/{2}'.format(request.app['pool'].minsize, request.app['pool'].size, request.app['pool'].maxsize))
            response = await tile_handler_on_conn(conn, request)
            return response
    except Exception as e:
        tile_exception.inc()
        logger.warning('Exception in tile handler pooling: %s', e)
        raise

async def logger_middleware(app, handler):
    """
    Middleware function that logs the HTTP method of each request.

    If there is an exception, no logs are produced and it the exception bubbles up
    and is caught by error_middleware.
    """
    async def logger_m(request):
        logger.info('Processing request %s %s', request.method, request.url)
        response = await handler(request)
        logger.info("Response status code: %d (for %s %s)", response.status, request.method, request.url)
        return response
    return logger_m

@web.middleware
async def error_middleware(request, handler):
    """
    This middleware function catches any exceptions that aren't HTTP exceptions and replaces them with a generic server error.
    """
    try:
        response = await handler(request)
        return response
    except web.HTTPException as ex:
        raise
    except:
        raise web.HTTPInternalServerError()

async def alive_handler(request):
    """
    This function handles the /probe/alive route. It increases the count of alive probes and returns a 200 OK response.
    """
    logger.info("Liveness check")
    tilesrv_aliveprobe.inc()
    return web.Response()

def metrics_to_string(m):
    return ''.join([x.report() for x in metrics])

async def metrics_handler(request):
    """
    Handles HTTP requests to the /metrics endpoint.

    Increments the scrape counter for metrics and returns a report of all collected metrics in Prometheus exposition format.

    Args:
        request (aiohttp.web.Request): The incoming HTTP request object.

    Returns:
        aiohttp.web.Response: The HTTP response containing metrics data in Prometheus format.
    """
    tilesrv_metrics_scraped.inc()
    return web.Response(text=metrics_to_string(metrics))

def osm_deg2num(lat_deg, lon_deg, zoom):
    """
    Converts geographical coordinates into OSM tile coordinates.

    Given a latitude and longitude in degrees, and a zoom level, this function computes
    the corresponding OSM tile (x, y) coordinates using the Slippy Map tilename algorithm.
    Args:
        lat_deg (float): Latitude in degrees.
        lon_deg (float): Longitude in degrees.
        zoom (int): Zoom level (typically 0-19).
    Returns:
        tuple: (xtile, ytile) tile coordinates as integers.
    References:
        - https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames
    """
    lat_rad = math.radians(lat_deg)
    n = 2.0 ** zoom
    xtile = int((lon_deg + 180.0) / 360.0 * n)
    ytile = int((1.0 - math.log(math.tan(lat_rad) + (1 / math.cos(lat_rad))) / math.pi) / 2.0 * n)
    return (xtile, ytile)

def num2deg(xtile, ytile, zoom):
    """
    Convert OSM tile coordinates to geographic latitude and longitude.

    Given the x and y tile indices and the zoom level, this function calculates the latitude and longitude
    of the northwest (top-left) corner of the specified tile in the OpenStreetMap tiling scheme.

    Use the function with xtile+1 and/or ytile+1 to get the other corners of the tile.
    With xtile+0.5 & ytile+0.5 it returns the centre of the tile.

    Parameters:
        xtile (int or float): The x-index of the tile.
        ytile (int or float): The y-index of the tile.
        zoom (int): The zoom level of the tile.

    Returns:
        tuple: A tuple (lat_deg, lon_deg) representing the latitude and longitude in degrees of the NW corner.

    Notes:
        - To get the coordinates of other corners, use xtile+1 and/or ytile+1.
        - To get the center of the tile, use xtile+0.5 and ytile+0.5.
    """
    n = 2.0 ** zoom
    lon_deg = xtile / n * 360.0 - 180.0
    lat_rad = math.atan(math.sinh(math.pi * (1 - 2 * ytile / n)))
    lat_deg = math.degrees(lat_rad)
    return (lat_deg, lon_deg)

def tile_bbox_from_coords(zoom, coord_bbox):
    """
    Calculate the bounding box of map tiles covering a geographic area at a specific zoom level, given the geographic bounding box.

    Args:
        zoom (int): The zoom level for which to calculate tile coordinates.
        coord_bbox (tuple): Geographic bounding box specified as (min_lon, min_lat, max_lon, max_lat).

    Returns:
        tuple: Tile bounding box as (tile_minx, tile_miny, tile_maxx, tile_maxy), representing the minimum and maximum tile coordinates covering the area.

    Note:
        This function relies on `osm_deg2num` to convert geographic coordinates to tile numbers.
    """
    (ax, ay) = osm_deg2num(coord_bbox[0], coord_bbox[1], zoom)
    (bx, by) = osm_deg2num(coord_bbox[2], coord_bbox[3], zoom)
    tile_minx = min(ax, bx)
    tile_maxx = max(ax, bx)
    tile_miny = min(ay, by)
    tile_maxy = max(ay, by)
    return (tile_minx, tile_miny, tile_maxx, tile_maxy)

async def app_factory():
    """
    Sets up and returns the aiohttp web application.
    """
    app = web.Application()
    if args.verbose:
        app.middlewares.append(logger_middleware)
    app.middlewares.append(error_middleware)
    app['dsn'] = make_osm_dsn()
    if connection_pooling:
        logger.info('Using connection pooling with DSN: %s', app['dsn'])
        app['pool'] = await aiopg.create_pool(app['dsn'], minsize=0, pool_recycle=30*60)

    # Assume ingress addding /tiles/
    app.add_routes([web.get(r'/{zoom:\d+}/{x:\d+}/{y:\d+}.json', tile_handler),
                    web.get('/probe/alive', alive_handler),
                    web.get('/metrics', metrics_handler)])
    return app

def make_osm_dsn():
    """
    Generates a PostgreSQL DSN (Data Source Name) string for connecting to a PostGIS-enabled database using environment variables.
    The function retrieves connection parameters (user, password, host, port, dbname) from environment variables and sets SSL mode to 'require'.

    Returns:
        str: The constructed DSN string.
    """
    dsn = make_dsn(
                    user=os.environ['POSTGIS_USER'],
                    password=os.environ['POSTGIS_PASSWORD'],
                    host=os.environ['POSTGIS_HOST'],
                    port=os.environ['POSTGIS_PORT'],
                    dbname=os.environ['POSTGIS_DBNAME'],
                    sslmode='require'
                )
    logger.info('Generated DSN: %s', dsn)
    return dsn

def main():
    global args
    global logger
    global tc
    global tile_handler

    parser = argparse.ArgumentParser(description='tile generator for Soundscape')
    parser.add_argument('--server', nargs=1, type=int, default=8080, help='server port')
    parser.add_argument('--verbose', '-v', action='store_true', help='verbose')

    args = parser.parse_args()

    if args.verbose:
        loglevel = logging.INFO
    else:
        loglevel = logging.WARNING

    logging.basicConfig(level=loglevel, format='%(asctime)s:%(levelname)s:%(message)s')
    logger = logging.getLogger()

    logger.warning('Starting server')
    tilesrv_start.inc()

    if connection_pooling:
        tile_handler = tile_handler_pooling
    else:
        tile_handler = tile_handler_no_pooling

    # Set up the OpenTelemetry components
    resource = Resource.create({"service.name": "tilesrv"})

    # Tracing
    tp = TracerProvider(resource=resource)
    tp.add_span_processor(BatchSpanProcessor(AzureMonitorTraceExporter()))
    otel_trace.set_tracer_provider(tp)

    # Instrument aiohttp using the tracer and meter providers we created.
    AioHttpServerInstrumentor().instrument(
        tracer_provider=tp
    )

    web.run_app(app_factory())

if __name__ == '__main__':
    main()
