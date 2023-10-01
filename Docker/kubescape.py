"""
This is a minimal shim to replace missing code referenced by ingest.py.
"""
import os
from psycopg2.extensions import make_dsn, parse_dsn

class SoundscapeKube:
    def __init__(self, arg1, arg2):
        self.databases = {
            'osm': {
                'name': 'osm',
                'dsn2': make_dsn(
                    user=os.environ['POSTGIS_USER'],
                    password=os.environ['POSTGIS_PASSWORD'],
                    host=os.environ['POSTGIS_HOST'],
                    port=os.environ['POSTGIS_PORT'],
                    dbname=os.environ['POSTGIS_DBNAME'],
                ),
                'dbstatus': None,
            }
        }

    def connect(self):
        pass

    def enumerate_databases(self):
        return self.databases.values()

    def get_database_status(self, db_name):
        return self.databases[db_name]['dbstatus']

    def set_database_status(self, db_name, status):
        self.databases[db_name]['dbstatus'] = status

    def get_url_dsn(self, dsn):
        args = parse_dsn(dsn)
        user = args.get('user', '')
        password = args.get('password', '')
        host = args.get('host', '')
        port = args.get('port', '')
        dbname = args.get('dbname', '')
        return f"postgis://{user}:{password}@{host}:{port}/{dbname}"

    def get_connstring_dsn(self, dsn):
        args = parse_dsn(dsn)
        user = args.get('user', '')
        password = args.get('password', '')
        host = args.get('host', '')
        port = args.get('port', '')
        dbname = args.get('dbname', '')
        return f"dbname={dbname} user={user} password={password} host={host}"