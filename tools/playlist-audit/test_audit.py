import tempfile
from pathlib import Path
import unittest
import json
import plistlib
import subprocess
import sys

from audit import analyze, inspect_track, local_path


class AuditTests(unittest.TestCase):
    def test_cli_preserves_source_and_refuses_to_overwrite_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_dir = root / 'source'
            source_dir.mkdir()
            source = source_dir / 'Library.xml'
            original = plistlib.dumps({'Tracks': {}, 'Playlists': []})
            source.write_bytes(original)
            output = root / 'private' / 'audit.json'
            command = [sys.executable, str(Path(__file__).with_name('audit.py')),
                       '--library', str(source), '--output', str(output)]
            first = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            report = output.read_bytes()
            self.assertTrue(json.loads(report)['source']['unchanged_at_end'])
            second = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(second.returncode, 0)
            self.assertIn('already exists', second.stderr)
            self.assertEqual(output.read_bytes(), report)
            blocked = subprocess.run(command[:-1] + [str(source_dir / 'audit.json')],
                                     capture_output=True, text=True)
            self.assertNotEqual(blocked.returncode, 0)
            self.assertFalse((source_dir / 'audit.json').exists())
            self.assertEqual(source.read_bytes(), original)

    def test_order_duplicates_missing_references_and_folder_precedence(self):
        library = {'Tracks': {'1': {'Persistent ID': 'track-one'}}, 'Playlists': [
            {'Name': 'Folder', 'Playlist Persistent ID': 'folder', 'Folder': True,
             'Smart Info': b'opaque'},
            {'Name': 'Mix', 'Playlist Persistent ID': 'mix', 'Parent Persistent ID': 'folder',
             'Playlist Items': [{'Track ID': 1}, {'Track ID': 2}, {'Track ID': 1}]},
            {'Name': 'System', 'Distinguished Kind': 1, 'Smart Criteria': b'unknown',
             'Playlist Persistent ID': 'system'}]}
        result = analyze(library)
        self.assertEqual([p['kind'] for p in result['playlists']], ['folder', 'ordinary', 'system'])
        self.assertEqual(result['playlists'][1]['duplicate_positions'], {'1': [1, 3]})
        self.assertEqual([x['track_id'] for x in result['playlists'][1]['items']], ['1', '2', '1'])
        self.assertEqual(result['summary']['broken_track_references'], 1)
        self.assertEqual(result['summary']['missing_parent_references'], 0)
        self.assertEqual(result['playlists'][0]['smart_data_base64']['Smart Info'], 'b3BhcXVl')

    def test_file_observation_is_not_eligibility(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Example #1 + song.mp3'
            path.write_bytes(b'fictional fixture, not playable audio')
            track = {'Location': path.as_uri(), 'Purchased': True}
            result = inspect_track(track)
            self.assertEqual(local_path(track['Location']), path)
            self.assertEqual(result['file_status'], 'readable')
            self.assertEqual(result['eligibility'], 'unresolved')
            self.assertEqual(result['protection'], 'not_verified')
            self.assertEqual(result['playability'], 'not_tested')
            self.assertEqual(path.read_bytes(), b'fictional fixture, not playable audio')
            path.unlink()
            self.assertEqual(inspect_track(track)['file_status'], 'missing')

    def test_no_location_is_not_missing_and_remote_not_contacted(self):
        self.assertEqual(inspect_track({})['file_status'], 'no_location')
        self.assertEqual(inspect_track({'Location': 'file://example.invalid/song.mp3'})['file_status'],
                         'location_not_checked')
        self.assertEqual(inspect_track({'Apple Music': True})['eligibility'], 'subscription_excluded')


if __name__ == '__main__':
    unittest.main()
