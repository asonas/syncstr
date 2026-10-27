"""NAS-side helper; accepts one JSON request on stdin and emits one receipt."""

import base64
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import uuid


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def write(path, value):
    temporary = path.with_name(path.name + '.tmp')
    with temporary.open('w', encoding='utf-8') as stream:
        json.dump(value, stream)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def cli(root, image, *args):
    result = subprocess.run(['docker', 'run', '--rm', '--network', 'none',
                             '--user', f'{os.getuid()}:{os.getgid()}',
                             '-v', f'{root}:/test', image, *args],
                            capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise ValueError(result.stderr.strip())


def database(root):
    return sqlite3.connect((root / 'data/node.sqlite').as_uri() + '?mode=ro', uri=True)


def verify(root, row):
    item = root / 'staging' / row['id']
    expected = read(item / 'entry.json')
    with closing(database(root)) as db:
        values = db.execute('SELECT payload FROM tracks WHERE sha256 = ?', (row['sha256'],)).fetchall()
        if len(values) != 1:
            raise ValueError('Expected exactly one stored track')
        actual = json.loads(values[0][0])
        organization = json.loads(db.execute('SELECT payload FROM organization').fetchone()[0])
        if organization.get('artwork'):
            for asset, payload in db.execute('SELECT id, payload FROM artwork_assets'):
                if asset in organization['artwork']['assets']:
                    organization['artwork']['assets'][asset] = base64.b64encode(payload).decode('ascii')
    audio = root / 'data/objects' / (row['sha256'] + '.' + row['suffix'])
    if audio.stat().st_size != row['size'] or digest(audio) != row['sha256']:
        raise ValueError('Stored audio integrity check failed')
    for field in ('title', 'artist', 'album', 'track', 'discNumber', 'size', 'suffix'):
        if actual['track'].get(field) != expected['track'].get(field):
            raise ValueError('Stored metadata differs: ' + field)
    actual_imported = actual.get('importedAlbum') or {}
    expected_imported = expected.get('importedAlbum') or {}
    if any(actual_imported.get(key) != expected_imported.get(key)
           for key in actual_imported.keys() | expected_imported.keys()):
        raise ValueError('Imported source metadata differs')
    source_org = read(item / 'organization.json')
    actual_track = next(t for t in organization['tracks'] if t['sha256'] == row['sha256'])
    if actual_track.get('importContext') != source_org['tracks'][0].get('importContext'):
        raise ValueError('Import context was not retained')
    if row['asset']:
        art = organization['artwork']
        if (hashlib.sha256(base64.b64decode(art['assets'][row['asset']])).hexdigest() != row['asset']
                or not any(c['track'] == actual_track['id'] and c['asset'] == row['asset']
                           and c['source'] == 'music' for c in art['candidates'])):
            raise ValueError('Source artwork was not retained')
    return {'sha256': row['sha256'], 'size': row['size'], 'metadata': 'verified',
            'artwork': 'verified' if row['asset'] else 'missing', 'track_id': actual['track']['id']}


def handle(request):
    import fcntl

    mode = request.get('mode')
    if mode not in ('isolated-test', 'existing-library'):
        raise ValueError('Unsupported destination mode')
    root = Path(request['root'])
    if (not re.fullmatch(r'/[A-Za-z0-9_./-]+', str(root)) or root != root.resolve()
            or len(root.parts) < 3):
        raise ValueError('Test root must be absolute, canonical and not a symlink')
    image = request['image']
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', image):
        raise ValueError('Image must be pinned by digest')
    token = str(uuid.UUID(request['token']))
    identity = {'mode': mode, 'root': str(root), 'image': image, 'token': token}
    if mode == 'existing-library':
        identity.update({key: request[key] for key in ('library_id', 'manifest_sha256', 'records')})
        if (str(uuid.UUID(identity['library_id'])) != identity['library_id']
                or not re.fullmatch(r'[0-9a-f]{64}', identity['manifest_sha256'])
                or not identity['records']):
            raise ValueError('Invalid existing library binding')
    marker = root / 'migration-destination.json'
    action = request['action']
    peer = 'data/peer' if mode == 'existing-library' else 'peer'
    if any((root / name).resolve() != root / name for name in ('data', peer, 'staging')):
        raise ValueError('Destination subdirectories must not follow symlinks')
    if mode == 'existing-library':
        if action == 'init':
            raise ValueError('An existing library cannot use init-test')
        with (root / 'data/node.lock').open('rb') as data_lock:
            fcntl.flock(data_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with closing(database(root)) as db:
                if db.execute('SELECT id FROM library').fetchone()[0] != identity['library_id']:
                    raise ValueError('Destination library identity changed')
                initialized = db.execute('SELECT count(*) FROM cluster_identity').fetchone()[0] == 1
            if not (root / peer / 'device.key').is_file():
                raise ValueError('Existing peer identity is missing')
            if action == 'bind' and not initialized and not request.get('initialize_cluster'):
                raise ValueError('Existing library needs explicit --initialize-cluster')
            if action == 'bind' and not marker.exists():
                write(marker, identity)
    if mode == 'isolated-test' and action == 'init' and not root.exists():
        root.mkdir(mode=0o700)
        write(marker, identity)
    if not marker.exists() or read(marker) != identity:
        raise ValueError('Destination marker mismatch; refusing an existing or production directory')
    with (root / 'migration.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if action == 'bind':
            if mode != 'existing-library':
                raise ValueError('Only existing libraries can be bound')
            if not initialized:
                cli(root, image, 'cluster-init', '--data', '/test/data', '--peer-state', '/test/' + peer)
        if action == 'init':
            if not (root / 'peer').exists():
                cli(root, image, 'peer-init', '--state', '/test/peer')
            initialized = False
            if (root / 'data/node.sqlite').exists():
                with closing(database(root)) as db:
                    table = db.execute("SELECT name FROM sqlite_master WHERE name='cluster_identity'").fetchone()
                    initialized = table and db.execute('SELECT count(*) FROM cluster_identity').fetchone()[0] == 1
            if not initialized:
                cli(root, image, 'cluster-init', '--data', '/test/data', '--peer-state', '/test/peer')
        with closing(database(root)) as db:
            library_id = db.execute('SELECT id FROM library').fetchone()[0]
        if request.get('library_id', library_id) != library_id:
            raise ValueError('Destination library identity changed')
        if action in ('init', 'bind', 'check'):
            return {'library_id': library_id}
        row = request['record']
        if mode == 'existing-library' and identity['records'].get(row['id']) != hashlib.sha256(
                json.dumps(row, sort_keys=True).encode()).hexdigest():
            raise ValueError('Record is outside the reviewed selection')
        if (str(uuid.UUID(row['id'])) != row['id'] or not re.fullmatch(r'[0-9a-f]{64}', row['sha256'])
                or row['suffix'] not in ('mp3', 'm4a', 'aac', 'flac', 'wav', 'aiff', 'aif', 'alac')):
            raise ValueError('Invalid record identity')
        item = root / 'staging' / row['id']
        if item.resolve() != item:
            raise ValueError('Staging must not follow symlinks')
        if action == 'stage':
            item.mkdir(parents=True, exist_ok=True)
            return {'ready': True}
        expected_files = {'entry.json', 'organization.json', 'source-evidence.json', 'audio.' + row['suffix']}
        if set(row['files']) != expected_files:
            raise ValueError('Invalid file list')
        for name, checksum in row['files'].items():
            if digest(item / name) != checksum:
                raise ValueError('Staged file hash mismatch: ' + name)
        entry = read(item / 'entry.json')
        if (entry['sha256'] != row['sha256'] or entry['track']['size'] != row['size']
                or row['files']['audio.' + row['suffix']] != row['sha256']):
            raise ValueError('Entry and audio evidence disagree')
        if action == 'import':
            prefix = '/test/staging/' + row['id']
            cli(root, image, 'cluster-import', '--data', '/test/data', '--peer-state', '/test/' + peer,
                '--entry', prefix + '/entry.json', '--organization', prefix + '/organization.json',
                '--file', prefix + '/audio.' + row['suffix'])
        elif action != 'verify':
            raise ValueError('Unknown operation')
        return verify(root, row)


if __name__ == '__main__':
    try:
        print(json.dumps(handle(json.load(sys.stdin))))
    except (OSError, ValueError, KeyError, StopIteration, sqlite3.Error, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
