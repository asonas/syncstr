"""Export matching metadata from a headless node using one read-only transaction."""

import argparse
import json
from pathlib import Path
import sqlite3
import sys


def export_catalog(database):
    uri = Path(database).resolve().as_uri() + '?mode=ro'
    with sqlite3.connect(uri, uri=True) as connection:
        connection.execute('PRAGMA query_only = ON')
        connection.execute('BEGIN')
        identity = connection.execute('SELECT id FROM library WHERE singleton = 1').fetchone()
        if identity is None:
            raise ValueError('Server library is not initialized')
        entries = []
        for (payload,) in connection.execute('SELECT payload FROM tracks ORDER BY id'):
            entry = json.loads(payload)
            entries.append({'track': entry['track'], 'sha256': entry['sha256']})
        row = connection.execute('SELECT payload FROM organization WHERE singleton = 1').fetchone()
        organization = json.loads(row[0]) if row else {}
        cluster = connection.execute('SELECT id FROM cluster_identity WHERE singleton = 1').fetchone()
        return {'id': identity[0], 'cluster_id': cluster[0] if cluster else None,
                'entries': entries, 'organization': {
                    'trackAliases': organization.get('trackAliases', {}),
                    'tracks': [{'id': t['id'], 'sha256': t['sha256']}
                               for t in organization.get('tracks', [])]}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database', type=Path, required=True)
    args = parser.parse_args()
    json.dump(export_catalog(args.database), sys.stdout, ensure_ascii=False, sort_keys=True)
    sys.stdout.write('\n')


if __name__ == '__main__':
    main()
