import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from inventory import inventory, observe_file, publish, safe_local


SCRIPT = Path(__file__).with_name('inventory.py')


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.input = self.root / 'source'
        self.input.mkdir()
        self.media = self.input / 'media'
        self.media.mkdir()
        self.audio = self.media / '曲 + percent%.mp3'
        self.audio.write_bytes(b'fictional audio')
        self.xml = self.input / 'Library.xml'
        self.output = self.root / 'inventory.json'
        self.catalog = self.root / 'catalog.json'
        self.review = self.root / 'review.json'
        self.library = {'Library Persistent ID': 'library-one', 'Music Folder': self.media.as_uri(),
                        'Tracks': {}, 'Playlists': []}

    def track(self, identity, path=None, **changes):
        return {'Persistent ID': identity, 'Name': 'Song', 'Artist': 'Artist', 'Album': 'Album',
                'Total Time': 10000, 'Location': (path or self.audio).as_uri(), **changes}

    def run_command(self, *args, success=True):
        result = subprocess.run([sys.executable, str(SCRIPT), *map(str, args)], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def scan(self, *args):
        self.xml.write_bytes(plistlib.dumps(self.library))
        original = self.xml.read_bytes(), self.audio.read_bytes()
        self.run_command('inventory', '--library', self.xml, '--output', self.output, *args)
        self.assertEqual(original, (self.xml.read_bytes(), self.audio.read_bytes()))
        return json.loads(self.output.read_text(encoding='utf-8'))

    def test_identical_audio_separate_registrations_and_playlist_occurrences(self):
        second = self.media / 'Song-1.mp3'
        second.write_bytes(self.audio.read_bytes())
        self.library['Tracks'] = {'1': self.track('one', Location=self.audio.as_uri().replace('%2B', '+')),
                                  '2': self.track('two'), '3': self.track('three', second)}
        self.library['Playlists'] = [{'Playlist Persistent ID': 'playlist', 'Smart Info': b'opaque',
                                     'Playlist Items': [{'Track ID': 1}, {'Track ID': 2}, {'Track ID': 1}, {'Track ID': 99}]}]
        result = self.scan()
        rows = result['tracks']
        self.assertEqual([r['identity']['stable_key'] for r in rows], [['library-one', p] for p in ('one', 'two', 'three')])
        expected_hash = hashlib.sha256(b'fictional audio').hexdigest()
        self.assertEqual([r['file']['sha256'] for r in rows], [expected_hash] * 3)
        self.assertEqual(rows[0]['location']['decoded_path'], str(self.audio))
        self.assertNotIn('Album Artist', rows[0]['metadata'])
        self.assertEqual([i['row_id'] for i in result['playlists'][0]['items']], ['0:1', '0:2', '0:1', None])
        self.assertEqual(result['summary']['broken_playlist_references'], 1)
        self.assertTrue(result['xml_unchanged_at_end'])
        self.run_command('inventory', '--library', self.xml, '--output', self.output, success=False)

    def test_reexports_and_different_library_scopes(self):
        self.library['Tracks'] = {'1': self.track('one', **{'Track ID': 1})}
        first = self.scan()
        second_xml = self.input / 'Other.xml'
        self.library['Tracks'] = {'22': self.track('one', **{'Track ID': 22})}
        self.library['Playlists'] = [{'Playlist Items': [{'Track ID': 22}]}]
        second_xml.write_bytes(plistlib.dumps(self.library))
        second_output = self.root / 'second.json'
        self.run_command('inventory', '--library', second_xml, '--output', second_output)
        second = json.loads(second_output.read_text())
        self.assertEqual(first['tracks'][0]['identity']['stable_key'], second['tracks'][0]['identity']['stable_key'])
        self.assertEqual(second['playlists'][0]['items'][0]['row_id'], '0:22')
        self.library['Library Persistent ID'] = 'library-two'
        second_xml.write_bytes(plistlib.dumps(self.library))
        multi = self.root / 'multi.json'
        self.run_command('inventory', '--library', self.xml, '--library', second_xml, '--output', multi)
        keys = [r['identity']['stable_key'] for r in json.loads(multi.read_text())['tracks']]
        self.assertEqual(keys, [['library-one', 'one'], ['library-two', 'one']])

    def test_invalid_ids_and_duplicate_exports_are_reported_without_merging(self):
        self.library['Tracks'] = {'1': self.track('duplicate'), '2': self.track('duplicate'), '3': self.track('')}
        del self.library['Tracks']['3']['Persistent ID']
        report = self.scan()
        self.assertEqual(report['summary']['invalid_identities'], 3)
        other = self.root / 'duplicate-exports.json'
        self.run_command('inventory', '--library', self.xml, '--library', self.xml, '--output', other)
        combined = json.loads(other.read_text())
        self.assertEqual(len(combined['tracks']), 6)
        self.assertTrue(all('duplicate_or_conflicting_library_id' in r['identity']['reasons'] for r in combined['tracks']))

    def test_sample_limit_retains_uninspected_registrations(self):
        self.library['Tracks'] = {'1': self.track('one'), '2': self.track('two')}
        report = self.scan('--file-limit', '1')
        self.assertEqual([r['file']['status'] for r in report['tracks']], ['available', 'not_sampled'])
        self.assertEqual(report['file_attempt_limit'], 1)
        self.assertEqual(report['summary']['registrations'], 2)
        self.assertNotIn('sha256', report['tracks'][1]['file'])

    def test_explicit_remapping_and_missing_protected_unavailable_rows(self):
        old = self.root / 'old-media'
        self.library['Tracks'] = {
            '1': self.track('one', old / self.audio.name),
            '2': self.track('two', self.media / 'missing.mp3'),
            '3': self.track('three', **{'Protected': True}),
            '4': {'Persistent ID': 'four'},
            '5': self.track('five', Location='file://server/share/song.mp3')}
        report = self.scan('--root-map', f'{old}={self.media}')
        self.assertEqual([r['file']['status'] for r in report['tracks']], ['available', 'missing', 'available', 'no_location', 'invalid'])
        self.assertEqual(report['tracks'][2]['protection'], 'flagged')
        self.assertEqual(report['tracks'][2]['eligibility'], 'unresolved')
        self.assertEqual(report['tracks'][0]['location']['root_mapping']['from'], str(old))
        rejected = self.root / 'ambiguous.json'
        self.run_command('inventory', '--library', self.xml, '--output', rejected,
                         '--root-map', f'{old}={self.media}', '--root-map', f'{old / "sub"}={self.media}', success=False)
        self.assertFalse(rejected.exists())
        self.run_command('inventory', '--library', self.xml, '--output', self.media / 'report.json', success=False)

    def test_review_retains_all_exact_entries_aliases_and_unaccepted_metadata(self):
        self.library['Tracks'] = {'1': self.track('one'), '2': self.track('two'),
                                  '3': self.track('three', self.media / 'missing.mp3')}
        self.scan()
        sha = hashlib.sha256(b'fictional audio').hexdigest()
        track = {'title': 'Song', 'artist': 'Artist', 'album': 'Album', 'duration': 10}
        self.catalog.write_text(json.dumps({'id': 'destination', 'entries': [
            {'sha256': sha, 'track': {**track, 'id': 'audio-one'}},
            {'sha256': sha, 'track': {**track, 'id': 'audio-two'}}],
            'organization': {'tracks': [{'id': 'logical', 'sha256': sha}], 'trackAliases': {'audio-one': 'logical'}}}))
        before = self.catalog.read_bytes()
        self.run_command('review', '--inventory', self.output, '--catalog', self.catalog, '--output', self.review)
        result = json.loads(self.review.read_text())
        self.assertEqual([r['status'] for r in result['tracks']], ['exact_bytes_candidate', 'exact_bytes_candidate', 'source_unavailable'])
        self.assertEqual([c['entry_track_id'] for c in result['tracks'][0]['candidates']], ['audio-one', 'audio-two'])
        self.assertEqual(result['tracks'][0]['candidates'][0]['canonical_track_id'], 'logical')
        self.assertTrue(all(r['decision'] is None for r in result['tracks']))
        self.assertTrue(all('shared_audio_requires_distinct_tracks' in r['flags'] for r in result['tracks']))
        self.assertEqual(before, self.catalog.read_bytes())
        self.run_command('review', '--inventory', self.output, '--catalog', self.catalog, '--output', self.review, success=False)
        empty_album = self.media / 'Empty album'
        empty_album.mkdir()
        self.run_command('review', '--inventory', self.output, '--catalog', self.catalog,
                         '--output', empty_album / 'review.json', success=False)
        self.assertFalse((empty_album / 'review.json').exists())

    def test_metadata_and_unmatched_and_invalid_source_are_distinct(self):
        self.library['Tracks'] = {'1': self.track('one'), '2': self.track('two', Name='Different'), '3': self.track('')}
        self.scan()
        self.catalog.write_text(json.dumps({'id': 'destination', 'entries': [{
            'sha256': 'b' * 64, 'track': {'id': 'dest', 'title': 'Song', 'artist': 'Artist', 'album': 'Album', 'duration': 11}}]}))
        self.run_command('review', '--inventory', self.output, '--catalog', self.catalog, '--output', self.review)
        rows = json.loads(self.review.read_text())['tracks']
        self.assertEqual([r['status'] for r in rows], ['metadata_candidate', 'unmatched', 'source_identity_invalid'])
        self.assertEqual(rows[0]['candidates'][0]['fields']['Total Time']['comparison'], 'different')
        self.assertEqual(rows[2]['candidates'][0]['basis'], 'metadata')

    def test_placeholder_read_error_and_changing_file_never_claim_a_hash(self):
        real_lstat = Path.lstat

        def placeholder(path, *args, **kwargs):
            info = real_lstat(path, *args, **kwargs)
            if path == self.audio:
                return type('Info', (), {'st_file_attributes': 0x400000, 'st_mode': info.st_mode})()
            return info

        with patch.object(Path, 'lstat', placeholder):
            self.assertEqual(observe_file(self.audio)['reason'], 'placeholder_not_read')
        with patch.object(Path, 'open', side_effect=PermissionError(13, 'fixture')):
            self.assertEqual(observe_file(self.audio)['read_status'], 'failed')
        actual_fstat = os.fstat
        calls = 0

        def change(descriptor):
            nonlocal calls
            calls += 1
            if calls == 2:
                with self.audio.open('ab') as handle:
                    handle.write(b'changed')
            return actual_fstat(descriptor)

        with patch('inventory.os.fstat', side_effect=change):
            result = observe_file(self.audio)
        self.assertEqual(result['hash_status'], 'unstable')
        self.assertNotIn('sha256', result)

    def test_interrupted_publication_and_changed_xml_leave_no_complete_report(self):
        with patch('inventory.os.link', side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                publish(self.output, {'complete': True})
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.root.glob('*.partial')), [])
        self.library['Tracks'] = {'1': self.track('one')}
        self.xml.write_bytes(plistlib.dumps(self.library))
        real_open = Path.open

        def edit_source(path, *args, **kwargs):
            if path == self.audio:
                self.xml.write_bytes(plistlib.dumps({**self.library, 'Date': 'changed'}))
            return real_open(path, *args, **kwargs)

        with patch.object(Path, 'open', edit_source):
            with self.assertRaisesRegex(ValueError, 'XML changed'):
                inventory([self.xml], self.output)
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
