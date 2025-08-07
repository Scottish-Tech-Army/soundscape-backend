import argparse
import logging
import os
import subprocess
import sys

parser = argparse.ArgumentParser(description='Ingestion diff engine for Soundscape')

# Arguments needed for Imposm to run incremental updates
parser.add_argument('--imposm', type=str, help='Imposm executable path', default='imposm')
parser.add_argument('--mapping', type=str, help='Mapping file path use by Imposm', default='mapping.yml')
#parser.add_argument('--where', metavar='regions', nargs='+', type=str, help='Region names for extracts that match the name key in extracts.json, for example, great-britain')
#parser.add_argument('--extracts', type=str, default='extracts.json', help='Extracts file which defines urls for extracts')
parser.add_argument('--config', type=str, help='Config file for fetching diffs.', default='config.json')
parser.add_argument('--basedir', type=str, help='Base dir for directories', default='/tmp')

# Logging
parser.add_argument('--verbose', action='store_true', help='Turn on verbose logging.')

CACHE_DIR = 'imposm_cache'
DIFF_DIR = 'imposm_diff'
EXPIRE_DIR = 'imposm_expired'
PBF_DIR = 'downloads'

def create_dsn_url():
        user=os.environ['POSTGIS_USER']
        password=os.environ['POSTGIS_PASSWORD']
        host=os.environ['POSTGIS_HOST']
        port=os.environ['POSTGIS_PORT']
        dbname=os.environ['POSTGIS_DBNAME']
        sslmode='require'
        return f"postgis://{user}:{password}@{host}:{port}/{dbname}?sslmode=require"

def run_diffs(config):
    # config.json controls where the diffs are downloaded from and how often it runs (1h)
    logger.info('Running diffs')
    dsn_url = create_dsn_url()
    imposm_cmd = [
         config.imposm, 'run',
         '-config', config.config,
         '-mapping', config.mapping,
         '-connection', dsn_url,
         '-srid', '4326',
         '-cachedir', f"{config.basedir}/{CACHE_DIR}",
         '-diffdir', f"{config.basedir}/{DIFF_DIR}",
         '-expiretiles-dir', f"{config.basedir}/{EXPIRE_DIR}",
         '-expiretiles-zoom', '16']
    logger.info("Running command: %s", imposm_cmd)
    subprocess.run(imposm_cmd, check=True)
    logger.info('Successful completion')

if __name__ == '__main__':
    args = parser.parse_args()

    if args.verbose:
        loglevel = logging.INFO
    else:
        loglevel = logging.WARNING

    logging.basicConfig(level=loglevel, format='%(asctime)s:%(levelname)s:%(message)s')
    logger = logging.getLogger()

    pbfdir = f"{args.basedir}/{PBF_DIR}"

    complete_file = os.path.join(pbfdir, 'INGEST_COMPLETE')
    if not os.path.exists(complete_file):
        # No previous run completed, so stop right now.
        logger.warning('File INGEST_COMPLETE does not exist in %s. Exiting.', pbfdir)
        sys.exit(1)

    with open(complete_file, 'r') as f:
        contents = f.read()
    logger.info('File INGEST_COMPLETE exists from previous run. Contents:\n%s', contents)

    try:
        run_diffs(args)

    finally:
        logger.warning("Exiting")
        logging.shutdown()