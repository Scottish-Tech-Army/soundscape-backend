import argparse
import logging
import json
import os
from datetime import datetime
import subprocess
import asyncio
import urllib.parse
import psycopg2
from psycopg2.extensions import make_dsn, parse_dsn
from psycopg2 import connect, OperationalError
import aiopg
import requests
from azure.identity import ManagedIdentityCredential
from azure.keyvault.secrets import SecretClient
import time

parser = argparse.ArgumentParser(description='Ingestion engine for Soundscape')
# Arguments needed for Imposm
parser.add_argument('--imposm', type=str, help='Imposm executable path', default='imposm')
parser.add_argument('--mapping', type=str, help='Mapping file path use by Imposm', default='mapping.yml')
parser.add_argument('--extracts', type=str, default='extracts.json', help='Extracts file which defines urls for extracts')
parser.add_argument('--config', type=str, help='Config file for fetching diffs.', default='config.json')
parser.add_argument('--basedir', type=str, help='Base dir for directories', default='/tmp')
parser.add_argument('--inc', action='store_true', help='Enable incremental mode', default=False)

# Logging
parser.add_argument('--verbose', action='store_true', help='Turn on verbose logging.')

CACHE_DIR = 'imposm_cache'
DIFF_DIR = 'imposm_diff'
EXPIRE_DIR = 'imposm_expired'
PBF_DIR = 'downloads'

def set_password():
    """
    Get the PostGIS password from environment variables or Azure Key Vault.
    """
    password = os.environ.get('POSTGIS_PASSWORD', '')

    if not password:
        logger.info('No POSTGIS_PASSWORD environment variable set, attempting to fetch from Azure Key Vault')
        key_vault_name = os.environ['KEY_VAULT_NAME']
        client_id = os.environ['CLIENT_ID']
        # Fetch the password from Azure Key Vault
        credential = ManagedIdentityCredential(client_id=client_id)
        client = SecretClient(vault_url=f"https://{key_vault_name}.vault.azure.net/", credential=credential)
        secret = client.get_secret('postgres-pw')
        password = secret.value
        if not password:
            raise ValueError('POSTGIS_PASSWORD not found in environment or Azure Key Vault')
        logger.info("Got password from Azure Key Vault")
        os.environ['POSTGIS_PASSWORD'] = password
    else:
        logger.info('POSTGIS_PASSWORD environment variable is set')

def make_osm_dsn():
    dsn = make_dsn(
                    user=os.environ['POSTGIS_USER'],
                    password=os.environ['POSTGIS_PASSWORD'],
                    host=os.environ['POSTGIS_HOST'],
                    port=os.environ['POSTGIS_PORT'],
                    dbname=os.environ['POSTGIS_DBNAME'],
                    sslmode='require'
                )
    return dsn

def get_url_dsn(dsn):
        args = parse_dsn(dsn)
        user = args.get('user', '')
        password = args.get('password', '')
        host = args.get('host', '')
        port = args.get('port', '')
        dbname = args.get('dbname', '')
        return f"postgis://{user}:{password}@{host}:{port}/{dbname}?sslmode=require"

def check_table(cursor, name, schema):
        """Check for tables in the DB table exists in the DB"""
        sql = """ SELECT EXISTS (SELECT 1 AS result from information_schema.tables
                 where table_name like  TEMP_TABLE and table_schema = 'TEMP_SCHEMA'); """
        cursor.execute(sql.replace('TEMP_TABLE', '%s' % name).replace('TEMP_SCHEMA', '%s' % schema))

        return cursor.fetchone()[0]

def fetch_extracts(config, extracts):
    logger.info('Fetch extracts: %s', extracts)
    for e in extracts:
        fetch_extract(config, e['url'])
    logger.info('Fetch extracts completed')

def fetch_extract(config, url):
    # Fetch an extract
    local_pbf = os.path.join(f"{config.basedir}/{PBF_DIR}", os.path.basename(url))

    try:
        # We set a connection and data timeout of 15 and 60 respectively
        logger.info('Downloading %s to %s', url, local_pbf)
        with requests.get(url, stream=True, timeout=(15, 60)) as r:
            r.raise_for_status()
            with open(local_pbf, 'wb') as f:
                for chunk in r.iter_content(chunk_size=8192):
                    f.write(chunk)
        after_token = os.path.getmtime(local_pbf)
    except Exception as e:
        logger.error(f"Error fetching {url}: {e}")
        raise

    logger.info('Download complete for %s', local_pbf)

def connect_to_postgresdb(dsn):
    try:
        # TODO: Need to change this so the db name isn't hardcoded
        # Need to enumerate db s. Will probably have to use psql
        dsn_init = dsn.replace('dbname=osm', 'dbname=postgres')
        connection = connect(dsn_init)
        cursor = connection.cursor()
        cursor.close()
        connection.close()

    except OperationalError as e:
        logger.warning('Unable to connect to "{0}: {1}": FAILED'.format("postgres", e))
        raise

async def provision_database_async(postgres_dsn, osm_dsn):
    async with aiopg.connect(dsn=postgres_dsn) as conn:
        cursor = await conn.cursor()
        try:
            await cursor.execute('CREATE DATABASE osm')
        except psycopg2.ProgrammingError:
            logger.warning('Unable to CREATE DATABASE osm - may already exist')
    async with aiopg.connect(dsn=osm_dsn) as conn:
        cursor = await conn.cursor()
        await cursor.execute('CREATE EXTENSION IF NOT EXISTS postgis')
        await cursor.execute('CREATE EXTENSION IF NOT EXISTS hstore')

def provision_database(postgres_dsn, osm_dsn):
    logger.info('Provisioning main database')
    loop = asyncio.get_event_loop()
    loop.run_until_complete(provision_database_async(postgres_dsn, osm_dsn))

def provision_database_soundscape(osm_dsn):
    logger.info('Provisioning Soundscape database')
    loop = asyncio.get_event_loop()
    loop.run_until_complete(provision_database_soundscape_async(osm_dsn))

async def provision_database_soundscape_async(osm_dsn):
    ingest_path = os.environ['INGEST']
    async with aiopg.connect(dsn=osm_dsn) as conn:
        cursor = await conn.cursor()
        with open(ingest_path + '/' + 'postgis-vt-util.sql', 'r') as sql:
            await cursor.execute(sql.read())
        with open(ingest_path + '/' + 'tilefunc.sql', 'r') as sql:
            await cursor.execute(sql.read())

def import_write(config):
    """
    Write the OSM tables to the database. Note that these are not live data
    until they are rotated later.
    """
    dsn = make_osm_dsn()
    dsn_url = get_url_dsn(dsn)

    logger.info('Delete old backups if they exist')
    delete_backup_tables(config, dsn_url)

    logger.info('Writing of OSM tables (incremental: %s): START', config.inc)
    imposm_args = [
        config.imposm, 'import',
        '-mapping', config.mapping,
        '-write',
        '-connection', dsn_url,
        '-srid', '4326',
        '-cachedir', f"{config.basedir}/{CACHE_DIR}"
    ]
    if config.inc:
        imposm_args.extend(['-diff', '-diffdir', f"{config.basedir}/{DIFF_DIR}"])
    logger.info('Running command: %s', ' '.join(imposm_args))
    subprocess.run(imposm_args, check=True)
    logger.info('Write of OSM tables: DONE')

def import_rotate(config):
    """
    Deploy to production. This renames the tables we loaded so they become the live data
    """
    logger.info('Table rotation: START')
    dsn = make_osm_dsn()
    dsn_url = get_url_dsn(dsn)
    imposm_args = [
        config.imposm, 'import',
            '-mapping', config.mapping,
            '-connection', dsn_url,
            '-srid', '4326',
            '-deployproduction',
            '-cachedir', f"{config.basedir}/{CACHE_DIR}"
            ]
    if config.inc:
        imposm_args.extend(['-diff', '-diffdir', f"{config.basedir}/{DIFF_DIR}"])
    logger.info('Running command: %s', ' '.join(imposm_args))
    subprocess.run(imposm_args, check=True)

    # Clean up backup tables
    delete_backup_tables(config, dsn_url)
    logger.info('Table rotation: DONE')

def delete_backup_tables(config, dsn_url):
    """
    Remove old backup tables.

    imposm creates these, but they just take up space and we never use them, so delete them.
    """
    logger.info('Deleting backup tables')
    imposm_args = [
        config.imposm, 'import',
            '-mapping', config.mapping,
            '-connection', dsn_url,
            '-removebackup'
        ]
    logger.info('Backup deletion command: %s', ' '.join(imposm_args))
    subprocess.run(imposm_args, check=True)
    logger.info('Backup tables deleted')

def connect_to_osmdb(dsn, config, osm_extracts):
    """
    This terribly named function connects to the OSM database, provisions it if necessary,
    and imports the OSM extracts.
    """
    try:
        # TODO: Change the strings to variables that we can pass in as args
        dsn_init = dsn.replace('dbname=osm', 'dbname=postgres')
        logger.info('Attempting to provision "{0}: ": PROVISIONING'.format(os.environ['POSTGIS_DBNAME']))
        provision_database(dsn_init, dsn)

        logger.info('Provisioning database complete - downloading')
        fetch_extracts(config, osm_extracts)

        logger.info('Download complete - reading, writing to tables')
        # Let Imposm do its stuff: read, import, write to db, rotate tables
        import_extracts(config, osm_extracts)
        import_write(config)
        import_rotate(config)
        # This deploys the .sql files onto the soundscape database
        provision_database_soundscape(dsn)

    except OperationalError as e:
        logger.warning('Unable to connect to "{0}: {1}": FAILED'.format(os.environ['POSTGIS_DBNAME'], e))
        raise

def import_extracts(config, extracts):
    """
    Loop through calling import_extract for each extract.
    """
    imported = {}
    for e, i in zip(extracts, range(len(extracts))):
        if i == 0:
            cache = '-overwritecache'
        else:
            cache = '-appendcache'
        urlbits = urllib.parse.urlsplit(e['url'])
        pbf = os.path.basename(urlbits.path)
        if pbf in imported:
            continue
        imported[pbf] = True
        import_extract(config, pbf, cache)

def import_extract(config, pbf, cache):
    """
    Read data into cache
    """
    logger.info('Read data into cache %s: START', pbf)
    imposm_args = [config.imposm, 'import',
                   '-mapping', config.mapping,
                   '-read', f"{config.basedir}/{PBF_DIR}/{pbf}",
                   '-srid', '4326',
                   cache,
                   '-cachedir', f"{config.basedir}/{CACHE_DIR}"]
    if config.inc:
        imposm_args.extend(['-diff', '-diffdir', f"{config.basedir}/{DIFF_DIR}"])
    logger.info('Running command: %s', ' '.join(imposm_args))
    subprocess.run(imposm_args, check=True)
    logger.info('Read data into cache %s: DONE', pbf)

def import_osm_data(config, osm_extracts):
    """
    Main function to import OSM data.

    Checks that the databases exist and provisions if required, then actually does the import
    """
    # check whether there is an existing OSM db and schema
    try:
        dsn = make_osm_dsn()
        # Can we connect to the postgres db?
        connect_to_postgresdb(dsn)
        # Connect to the osm db and do all the work.
        connect_to_osmdb(dsn, config, osm_extracts)

    except OperationalError as e:
        logger.warning('Unable to connect to "{0}: {1}": FAILED'.format(config.postgis_dbname, e))

if __name__ == '__main__':
    args = parser.parse_args()

    if args.verbose:
        loglevel = logging.INFO
    else:
        loglevel = logging.WARNING

    logging.basicConfig(level=loglevel, format='%(asctime)s:%(levelname)s:%(message)s')
    logger = logging.getLogger()
    logger.info('Simple ingestion engine started')

    # Remember the start time for logging
    start_time = time.time()

    # Log args except for the password
    args_dict = vars(args)
    args_dict['POSTGIS_PASSWORD'] = '***'
    logger.info('Arguments: %s', args_dict)

    # Make sure that the password is set; if not this sets it.
    set_password()

    # Check that the pbfdir exists, and create if not.
    pbfdir = f"{args.basedir}/{PBF_DIR}"
    if not os.path.exists(pbfdir):
        logger.info('Creating pbfdir: %s', pbfdir)
        os.makedirs(pbfdir)

    # Where indicates the extracts file to use.
    logger.info('Extracts to be processed from: %s', args.extracts)
    with open(args.extracts, 'r') as extracts_file:
        osm_extracts = json.load(extracts_file)
    region_names = [e['name'] for e in osm_extracts]
    logger.info('List of extract region names: %s', region_names)

    try:
        import_osm_data(args, osm_extracts)

        # When completed, create a file called 'ingest_complete' in the pbfdir
        complete_file = os.path.join(pbfdir, 'INGEST_COMPLETE')
        with open(complete_file, 'w') as f:
            f.write(f"Ingestion of {args.extracts} completed at {datetime.now().isoformat()}\n")
        logger.info('Ingestion completed successfully. File created: %s', complete_file)

        elapsed_time = int(time.time() - start_time)
        hours = elapsed_time // 3600
        minutes = (elapsed_time % 3600) // 60
        seconds = elapsed_time % 60
        logger.info('Total ingestion time: %d seconds (%d:%02d:%02d hh:mm:ss)', elapsed_time, hours, minutes, seconds)

    except Exception as e:
        logger.error('An error occurred during ingestion: %s', e)
        raise

    finally:
        logging.shutdown()