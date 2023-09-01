import argparse
import logging
from psycopg2.extensions import make_dsn, parse_dsn
import os
import subprocess

parser = argparse.ArgumentParser(description='Ingestion diff engine for Soundscape')

# Arguments needed for Imposm to run incremental updates
parser.add_argument('--imposm', type=str, help='Imposm executable path', default='imposm')
parser.add_argument('--mapping', type=str, help='Mapping file path use by Imposm', default='mapping.yml')
#parser.add_argument('--where', metavar='regions', nargs='+', type=str, help='Region names for extracts that match the name key in extracts.json, for example, great-britain')
#parser.add_argument('--extracts', type=str, default='extracts.json', help='Extracts file which defines urls for extracts')
parser.add_argument('--config', type=str, help='Config file for fetching diffs.', default='config.json')
parser.add_argument('--cachedir', type=str, help='Imposm temp directory where coords, nodes, relations and ways are stored', default='/tmp/imposm3_cache')
parser.add_argument('--diffdir', type=str, help='Imposm diff directory location', default='/tmp/imposm3_diffdir')
#parser.add_argument('--pbfdir', type=str, help='Where the extracts are stored in .pbf format', default='.')
parser.add_argument('--expiredir', type=str, help='Expired tiles directory', default='/tmp/imposm3_expiredir')

# Logging
parser.add_argument('--verbose', action='store_true', help='Turn on verbose logging.')

def make_osm_dsn(args):
    dsn = make_dsn(
                    user=os.environ['POSTGIS_USER'],
                    password=os.environ['POSTGIS_PASSWORD'],
                    host=os.environ['POSTGIS_HOST'],
                    port=os.environ['POSTGIS_PORT'],
                    dbname=os.environ['POSTGIS_DBNAME'],
                )
    return dsn

def get_url_dsn(dsn):
        args = parse_dsn(dsn)
        user = args.get('user', '')
        password = args.get('password', '')
        host = args.get('host', '')
        port = args.get('port', '')
        dbname = args.get('dbname', '')
        return f"postgis://{user}:{password}@{host}:{port}/{dbname}"

def run_diffs(config):
    
    # config.json controls where the diffs are downloaded from and how often it runs (1h)
    dsn = make_osm_dsn(config)
    dsn_url = get_url_dsn(dsn)    
    logger.info('Incremental update - STARTED')
    subprocess.run([config.imposm, 'run', '-config', config.config, '-mapping', config.mapping, '-connection', dsn_url, '-srid', '4326', '-cachedir', config.cachedir, '-diffdir', config.diffdir, '-expiretiles-dir', config.expiredir, '-expiretiles-zoom', '16'], check=True)
    logger.info('Incremental update - DONE')    

if __name__ == '__main__':
    args = parser.parse_args()

    if args.verbose:
        loglevel = logging.INFO
    else:
        loglevel = logging.WARNING            

    logging.basicConfig(level=loglevel, format='%(asctime)s:%(levelname)s:%(message)s')
    logger = logging.getLogger()

    try:
        run_diffs(args)

    finally:
        print('Terminating logging')
        logging.shutdown()