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
# This Python code is a server application for generating map tiles based on OpenStreetMap (OSM)
# data that has been previously loaded into a PostGIS database.

# It leverages asyncio, aiohttp, and aiopg for asynchronous operation and PostgreSQL connectivity.

# Key functionalities of this code are:

# Tile Generation: It generates map tiles based on a specified zoom level, x, and y coordinates.

# These tiles are created in a canonical form and serialized into a JSON object.

# This ensures that when tiles are generated from scratch, they will be identical if given identical input.

# HTTP Request Handling: The aiohttp library is used to handle incoming HTTP requests,
# specifically GET requests for tile data.

# These requests include a zoom level and the x and y coordinates of the requested tile.

# The application responds with the requested map tile in JSON format.

# The application also handles "probe" requests to verify if the server is alive, as well as requests for server metrics.

# Error Handling and Logging: If a request encounters an error (for instance, an exception during tile generation, or the request zoom level not matching the default),
# the application has mechanisms in place to log these errors and respond appropriately, often with a HTTP error code.

# Metrics and Performance Tracking: The application tracks various metrics like the number of times tiles are served, exceptions, query failures, server start counts,
# aliveness probes, and metrics requests. It also tracks histograms of tile query performance and tile sizes.

# Connection Pooling: The application uses aiopg's connection pooling to manage database connections efficiently.

# Command-Line Argument Parsing: This code can be customized when run from the command line, allowing the user to specify the server port, the Postgres connection string (DSN), and options for verbosity and telemetry.

# Overall, the primary purpose of this code is to serve as an HTTP tile server, capable of generating and serving map tiles from a PostGIS database based on HTTP requests.


import os
import math
import time
from datetime import datetime

import json
from collections import namedtuple
import argparse
import logging

import aiopg
import psycopg2
from psycopg2.extras import NamedTupleCursor

from kubescape import SoundscapeKube

from aiohttp import web

class StatCounter(object):
    #StatCounter: This class is used to count certain events, like number of tiles served or number of exceptions that occurred.
    #The inc() method increments the counter, and report() returns a formatted string reporting the counter's current value.

    def __init__(self, name, help):
        self.name = name
        self.help = help
        self.value = 0

    def inc(self):
        self.value += 1

    def report(self):
        f = '# HELP {name} {help}\n# TYPE {name} counter\n{name} {value}\n'
        s = f.format(name=self.name, help = self.help, value = self.value)
        return s

#This class is used to record a histogram of data samples for events such as query times or tile sizes.
#It has methods for sampling values (sample()) and reporting the histogram in a formatted string (report()).

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

timeout_set = "set statement_timeout=10000"

def tile_name(zoom, x, y,): #Returns the formatted string for the tile name.
    return '{0}/{1}/{2}.json'.format(zoom, x, y)

async def gentile_async(cursor, zoom, x, y, gather_metrics=False): #Asynchronously generates a tile based on the zoom level, x, and y coordinates, then returns the tile as a JSON string.
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
        print(e)
        raise

async def tile_handler_on_conn(conn, request): #Handles a tile request using an open database connection.
    start = datetime.utcnow()
    async with conn.cursor(cursor_factory=NamedTupleCursor) as cursor:
        zoom = request.match_info['zoom']
        if int(zoom) != zoom_default:
            raise web.HTTPNotFound()
        x = int(request.match_info['x'])
        y = int(request.match_info['y'])
        tile_data = await gentile_async(cursor, zoom, x, y, True)
        if tile_data == None:
            logger.info('ERROR GET {0}/{1}/{2}.json'.format(zoom, x, y))
            always_log('TILE_ERROR')
            tile_queryfail.inc()
            raise web.HTTPServiceUnavailable()
        else:
            tile_served.inc()
            end = datetime.utcnow()
            telemetry_log('request', start, end)
            return web.Response(text=tile_data, content_type='application/json')

async def tile_handler_no_pooling(request): #Creates a new database connection to handle a tile request. It is used when connection pooling is not enabled.
    try:
        async with aiopg.connect(request.app['dsn']) as conn:
            response = await tile_handler_on_conn(conn, request)
            return response
    except Exception:
        tile_exception.inc()
        raise

async def tile_handler_pooling(request):#Retrieves a connection from the connection pool to handle a tile request. It is used when connection pooling is enabled.
    try:
        async with request.app['pool'].acquire() as conn:
            always_log('pool: {0}/{1}/{2}'.format(request.app['pool'].minsize, request.app['pool'].size, request.app['pool'].maxsize))
            response = await tile_handler_on_conn(conn, request)
            return response
    except Exception as e:
        tile_exception.inc()
        raise

async def logger_middleware(app, handler):# This is a middleware function that logs the HTTP method of each request.
    async def logger_m(request):
        logger.warning('REQUEST {0}'.format(request.method))
        return await handler(request)
    return logger_m

@web.middleware
async def error_middleware(request, handler):# This middleware function catches any exceptions that aren't HTTP exceptions and replaces them with a generic server error.
    try:
        response = await handler(request)
        return response
    except web.HTTPException as ex:
        raise
    except:
        raise web.HTTPInternalServerError()

async def alive_handler(request):#This function handles the /probe/alive route. It increases the count of alive probes and returns a 200 OK response.
    always_log('ALIVE CHECK')
    tilesrv_aliveprobe.inc()
    return web.Response()

def metrics_to_string(m):
    return ''.join([x.report() for x in metrics])

async def metrics_handler(request):# Handles the /metrics route. It increases the count of metrics scrapes and returns a report of all metrics.
    tilesrv_metrics_scraped.inc()
    return web.Response(text=metrics_to_string(metrics))

# standard tile to coordinates and reverse versions from
# https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames

def osm_deg2num(lat_deg, lon_deg, zoom): #Converts geographical coordinates into OSM tile coordinates.
    lat_rad = math.radians(lat_deg)
    n = 2.0 ** zoom
    xtile = int((lon_deg + 180.0) / 360.0 * n)
    ytile = int((1.0 - math.log(math.tan(lat_rad) + (1 / math.cos(lat_rad))) / math.pi) / 2.0 * n)
    return (xtile, ytile)

# This returns the NW-corner of the square. Use the function with xtile+1 and/or ytile+1 to get the other corners. With xtile+0.5 & ytile+0.5 it will return the center of the tile.
def num2deg(xtile, ytile, zoom):#Converts OSM tile coordinates into geographical coordinates.
    n = 2.0 ** zoom
    lon_deg = xtile / n * 360.0 - 180.0
    lat_rad = math.atan(math.sinh(math.pi * (1 - 2 * ytile / n)))
    lat_deg = math.degrees(lat_rad)
    return (lat_deg, lon_deg)

def tile_bbox_from_coords(zoom, coord_bbox):#Returns the tile bounding box for a given geographical bounding box and zoom level.
    (ax, ay) = osm_deg2num(coord_bbox[0], coord_bbox[1], zoom)
    (bx, by) = osm_deg2num(coord_bbox[2], coord_bbox[3], zoom)
    tile_minx = min(ax, bx)
    tile_maxx = max(ax, bx)
    tile_miny = min(ay, by)
    tile_maxy = max(ay, by)
    return (tile_minx, tile_miny, tile_maxx, tile_maxy)

def always_log(s):# Logs a string message with a timestamp.
    print('{0}: {1}'.format(datetime.now(), s))

def telemetry_log(event_name, start, end, extra=None):#Logs telemetry data for an event.
    if args.telemetry:
        if extra == None:
            extra = {}
        extra['start'] = start.isoformat()
        extra['end'] = end.isoformat()

async def app_factory():# Sets up and returns an aiohttp web application.
    app = web.Application()
    if args.verbose:
        app.middlewares.append(logger_middleware)
    app.middlewares.append(error_middleware)

    kube = SoundscapeKube(None, "soundscape")
    kube.connect()

    for d in kube.enumerate_databases():
        try:
            args.dsn = kube.get_connstring_dsn(d['dsn2'])
        except Exception as e:
            logger.warning('failed gettting database creds "{0}: {1}"'.format(d['name'], e))

    app['dsn'] = args.dsn
    if connection_pooling:
        app['pool'] = await aiopg.create_pool(app['dsn'], minsize=0, pool_recycle=30*60)

    # assume ingress addding /tiles/
    app.add_routes([web.get(r'/{zoom:\d+}/{x:\d+}/{y:\d+}.json', tile_handler),
                    web.get('/probe/alive', alive_handler),
                    web.get('/metrics', metrics_handler)])
    return app

def main():#This function parses command line arguments, sets up logging, initializes the tile server, and starts the web application.
    global args
    global logger
    global tc
    global tile_handler

    dsn_default_base = 'host=localhost '
    dsn_default = dsn_default_base + 'user=osm password=osm dbname=osm'

    parser = argparse.ArgumentParser(description='tile generator for Soundscape')
    parser.add_argument('--server', nargs=1, type=int, default=8080, help='server port')
    parser.add_argument('--dsn', type=str, help='postgres dsn', default=dsn_default)
    parser.add_argument('--verbose', '-v', action='store_true', help='verbose')
    parser.add_argument('--telemetry', action='store_true', help='enable telemetry')

    args = parser.parse_args()

    # if args.verbose:
    #     loglevel = logging.INFO
    # else:
    #     loglevel = logging.WARNING
    loglevel = logging.WARNING

    logging.basicConfig(level=loglevel,
                    format='%(asctime)s:%(levelname)s:%(message)s')
    logger = logging.getLogger()
    if args.telemetry:
        pass

    always_log('start server')
    tilesrv_start.inc()

    if connection_pooling:
        tile_handler = tile_handler_pooling
    else:
        tile_handler = tile_handler_no_pooling

    web.run_app(app_factory())

if __name__ == '__main__':
    main()

# All these functions together form the backbone of the tile server application.
# They handle the processes of requesting and generating tiles, as well as tracking and logging various aspects of the application's performance.