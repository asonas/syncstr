import tempfile
from pathlib import Path
import unittest

from audit import analyze, inspect_track, local_path


class AuditTests(unittest.TestCase):
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
