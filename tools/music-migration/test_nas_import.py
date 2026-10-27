from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
import uuid

from nas_import import handle, verify


class PersistedCatalogTests(unittest.TestCase):
    @unittest.skipUnless(os.name == 'posix', 'NAS advisory locks require POSIX')
    def test_existing_binding_rejects_wrong_library_unreviewed_records_and_live_store(self):
        import fcntl

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / 'data/peer').mkdir(parents=True)
            (root / 'data/node.lock').touch()
            (root / 'data/peer/device.key').write_bytes(b'fixture; no runtime is invoked')
            library_id = str(uuid.uuid4())
            with closing(sqlite3.connect(root / 'data/node.sqlite')) as db:
                db.executescript('CREATE TABLE library(id TEXT); CREATE TABLE cluster_identity(id TEXT);')
                db.execute('INSERT INTO library VALUES (?)', (library_id,))
                db.execute('INSERT INTO cluster_identity VALUES (?)', ('fixture-cluster',))
                db.commit()
            row = {'id': str(uuid.uuid4()), 'sha256': 'b' * 64, 'suffix': 'mp3'}
            request = {'root': str(root), 'mode': 'existing-library', 'image': 'sha256:' + 'a' * 64,
                       'token': str(uuid.uuid4()), 'library_id': library_id, 'manifest_sha256': 'c' * 64,
                       'records': {row['id']: hashlib.sha256(json.dumps(row, sort_keys=True).encode()).hexdigest()}}
            with self.assertRaisesRegex(ValueError, 'identity changed'):
                handle({**request, 'action': 'bind', 'library_id': str(uuid.uuid4())})
            self.assertFalse((root / 'migration-destination.json').exists())
            self.assertEqual(handle({**request, 'action': 'bind'})['library_id'], library_id)
            with self.assertRaisesRegex(ValueError, 'outside the reviewed selection'):
                handle({**request, 'action': 'stage', 'record': {**row, 'sha256': 'd' * 64}})
            self.assertFalse((root / 'staging').exists())
            with (root / 'data/node.lock').open('rb') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(BlockingIOError):
                    handle({**request, 'action': 'stage', 'record': row})
            self.assertTrue(handle({**request, 'action': 'stage', 'record': row})['ready'])

    def test_verification_reads_externalized_artwork_and_absent_optional_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            item = root / 'staging/track-one'
            item.mkdir(parents=True)
            (root / 'data/objects').mkdir(parents=True)
            audio = b'fixture for the stored-byte verification boundary'
            image = b'fixture for the stored-image verification boundary'
            sha = hashlib.sha256(audio).hexdigest()
            asset = hashlib.sha256(image).hexdigest()
            track = {'id': 'track-one', 'title': 'Song', 'album': 'Album', 'artist': 'Artist',
                     'size': len(audio), 'suffix': 'mp3'}
            expected = {'track': track, 'sha256': sha,
                        'importedAlbum': {'title': 'Album', 'albumArtist': None, 'compilationValues': []}}
            actual = json.loads(json.dumps(expected))
            del actual['importedAlbum']['albumArtist']
            org = {'tracks': [{'id': 'track-one', 'sha256': sha,
                              'importContext': {'sourceID': 'library', 'folder': 'release'}}],
                   'artwork': {'assets': {asset: ''}, 'candidates': [
                       {'track': 'track-one', 'source': 'music', 'asset': asset}]}}
            (item / 'entry.json').write_text(json.dumps(expected))
            (item / 'organization.json').write_text(json.dumps(org))
            (root / 'data/objects' / (sha + '.mp3')).write_bytes(audio)
            with closing(sqlite3.connect(root / 'data/node.sqlite')) as db:
                db.executescript('CREATE TABLE tracks(sha256 TEXT,payload BLOB);'
                                 'CREATE TABLE organization(payload BLOB);'
                                 'CREATE TABLE artwork_assets(id TEXT,payload BLOB);')
                db.execute('INSERT INTO tracks VALUES (?,?)', (sha, json.dumps(actual)))
                db.execute('INSERT INTO organization VALUES (?)', (json.dumps(org),))
                db.execute('INSERT INTO artwork_assets VALUES (?,?)', (asset, image))
                db.commit()
            row = {'id': 'track-one', 'sha256': sha, 'size': len(audio), 'suffix': 'mp3', 'asset': asset}
            self.assertEqual(verify(root, row)['artwork'], 'verified')
            with closing(sqlite3.connect(root / 'data/node.sqlite')) as db:
                db.execute('UPDATE artwork_assets SET payload = ?', (b'corrupt',))
                db.commit()
            with self.assertRaisesRegex(ValueError, 'artwork was not retained'):
                verify(root, row)
