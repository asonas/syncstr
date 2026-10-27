"""SSH transfer with destination-bound, atomic progress records."""

from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import uuid


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def write_json(path, data):
    path = Path(path)
    temporary = path.with_name(path.name + '.tmp')
    with temporary.open('w', encoding='utf-8', newline='\n') as stream:
        json.dump(data, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


@contextmanager
def run_lock(path):
    with path.open('a+b') as stream:
        stream.seek(0, 2)
        if not stream.tell():
            stream.write(b'0')
            stream.flush()
        stream.seek(0)
        if os.name == 'nt':
            import msvcrt
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield


def remote(destination, action, **fields):
    if (not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.@-]*', destination['host'])
            or not re.fullmatch(r'/[A-Za-z0-9_./-]+', destination['root'])
            or '..' in destination['root'].split('/')):
        raise ValueError('Invalid destination host or path')
    helper = Path(__file__).with_name('nas_import.py')
    remote_helper = '/tmp/syncstr-migration-' + digest(helper) + '.py'
    subprocess.run(['scp', '-q', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                    str(helper.resolve()), destination['host'] + ':' + remote_helper], check=True)
    request = {**destination, 'action': action, **fields}
    result = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                             destination['host'], 'python3 ' + shlex.quote(remote_helper)],
                            input=json.dumps(request), capture_output=True, text=True, encoding='utf-8')
    if result.returncode:
        raise ValueError('NAS operation failed: ' + result.stderr.strip())
    return json.loads(result.stdout)


def initialize(host, root, image, output):
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.@-]*', host):
        raise ValueError('Use a named SSH host or user@host without options')
    if not re.fullmatch(r'/[A-Za-z0-9_./-]+', root) or '..' in root.split('/'):
        raise ValueError('Use an absolute NAS test path without shell characters')
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', image):
        raise ValueError('Pin the Docker image by sha256 digest')
    output.parent.mkdir(parents=True, exist_ok=True)
    destination = {'format_version': 1, 'host': host, 'root': root,
                   'image': image, 'token': str(uuid.uuid4()), 'mode': 'isolated-test'}
    if output.exists():
        previous = read_json(output)
        if any(previous.get(key) != destination[key] for key in ('host', 'root', 'image', 'mode')):
            raise ValueError('Destination descriptor belongs to another target')
        destination = previous
    # Retain the token even if the reply is interrupted; retrying init is idempotent.
    write_json(output, destination)
    result = remote(destination, 'init')
    destination['library_id'] = result['library_id']
    write_json(output, destination)
    print('Independent test destination initialized')


def validate_bundle(bundle):
    manifest = read_json(bundle / 'manifest.json')
    if manifest.get('format_version') != 1 or not manifest.get('tracks'):
        raise ValueError('Unsupported or incomplete prepared bundle')
    ids, hashes = set(), set()
    for row in manifest['tracks']:
        if str(uuid.UUID(row['id'])) != row['id'] or row['id'] in ids or row['sha256'] in hashes:
            raise ValueError('Duplicate or invalid prepared identity')
        ids.add(row['id'])
        hashes.add(row['sha256'])
        expected = {'entry.json', 'organization.json', 'source-evidence.json', 'audio.' + row['suffix']}
        if (row['suffix'] not in ('mp3', 'm4a', 'aac', 'flac', 'wav', 'aiff', 'aif', 'alac')
                or set(row['files']) != expected):
            raise ValueError('Invalid prepared file list')
        for name, checksum in row['files'].items():
            if digest(bundle / row['id'] / name) != checksum:
                raise ValueError('Prepared bundle changed; create a new reviewed run')
    return manifest


def bind_existing(host, root, image, library_id, bundle, output, initialize_cluster=False):
    manifest = validate_bundle(bundle)
    destination = {'format_version': 1, 'host': host, 'root': root, 'image': image,
                   'token': str(uuid.uuid4()), 'mode': 'existing-library',
                   'library_id': library_id, 'manifest_sha256': digest(bundle / 'manifest.json'),
                   'records': {row['id']: hashlib.sha256(json.dumps(row, sort_keys=True).encode()).hexdigest()
                               for row in manifest['tracks']}}
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        previous = read_json(output)
        if any(previous.get(key) != value for key, value in destination.items() if key != 'token'):
            raise ValueError('Destination descriptor belongs to another target or selection')
        destination = previous
    write_json(output, destination)
    remote(destination, 'bind', initialize_cluster=initialize_cluster)
    print('Existing library bound to the reviewed selection')


def migrate(bundle, destination_path, run, resume=False, approve_existing_library=None):
    if resume:
        state = read_json(run / 'progress.json')
        bundle = Path(state['bundle'])
        destination_path = Path(state['destination_path'])
    else:
        if run.exists():
            raise ValueError('Run already exists; use resume')
        bundle = bundle.resolve()
        destination_path = destination_path.resolve()
        if bundle == run.resolve() or bundle in run.resolve().parents:
            raise ValueError('Run state must be outside the prepared bundle')
        state = None
    manifest = validate_bundle(bundle)
    destination = read_json(destination_path)
    if destination.get('mode') not in ('isolated-test', 'existing-library') or not destination.get('library_id'):
        raise ValueError('Only initialized or explicitly bound destinations are supported')
    if destination['mode'] == 'existing-library':
        if approve_existing_library != destination['library_id']:
            raise ValueError('Existing library import requires --approve-existing-library with its library ID')
        if destination['manifest_sha256'] != digest(bundle / 'manifest.json'):
            raise ValueError('Bundle does not match the bound selection')
    binding = hashlib.sha256(json.dumps(destination, sort_keys=True).encode()).hexdigest()
    manifest_hash = digest(bundle / 'manifest.json')
    if resume:
        if state['destination_binding'] != binding or state['manifest_sha256'] != manifest_hash:
            raise ValueError('Destination or manifest changed; resume refused')
    else:
        run.mkdir(parents=True)
        state = {'format_version': 1, 'bundle': str(bundle), 'destination_path': str(destination_path),
                 'destination_binding': binding, 'manifest_sha256': manifest_hash, 'completed': {}}
        write_json(run / 'progress.json', state)
    with run_lock(run / 'run.lock'):
        remote(destination, 'check')
        for index, row in enumerate(manifest['tracks']):
            if row['id'] in state['completed']:
                receipt = remote(destination, 'verify', record=row)
            else:
                remote(destination, 'stage', record=row)
                target = destination['host'] + ':' + destination['root'] + '/staging/' + row['id'] + '/'
                subprocess.run(['scp', '-q', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                                *[str(bundle / row['id'] / name) for name in row['files']], target], check=True)
                receipt = remote(destination, 'import', record=row)
            if receipt.get('sha256') != row['sha256'] or receipt.get('size') != row['size']:
                raise ValueError('NAS did not confirm the expected audio')
            if receipt.get('metadata') != 'verified' or receipt.get('artwork') != ('verified' if row['asset'] else 'missing'):
                raise ValueError('NAS did not confirm metadata and artwork')
            state['completed'][row['id']] = receipt
            write_json(run / 'progress.json', state)
            print(f'Verified {index + 1}/{len(manifest["tracks"])}', flush=True)
