import csv
import json
from pathlib import Path
import plistlib
import sqlite3
import tempfile
import unittest

from export_server_catalog import export_catalog
from review import create_review, prepare


class ReviewTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.library = self.root / 'library.xml'
        self.catalog = self.root / 'catalog.json'
        self.review = self.root / 'review'
        self.source = {'Library Persistent ID': 'source-library', 'Tracks': {
            '1': {'Persistent ID': 'track-one', 'Name': 'One', 'Artist': 'Artist',
                  'Album': 'Album', 'Total Time': 120000, 'Track Number': 1},
            '2': {'Persistent ID': 'track-two', 'Name': 'Missing', 'Artist': 'Artist',
                  'Album': 'Album', 'Total Time': 120000}}, 'Playlists': [
            {'Playlist Persistent ID': 'folder', 'Name': 'Folder', 'Folder': True,
             'Smart Info': b'folder-not-playlist'},
            {'Playlist Persistent ID': 'manual', 'Name': 'Mix', 'Parent Persistent ID': 'folder',
             'Playlist Items': [{'Track ID': 1}, {'Track ID': 2}, {'Track ID': 1}, {'Track ID': 99}]},
            {'Playlist Persistent ID': 'smart', 'Name': 'Smart', 'Parent Persistent ID': 'folder',
             'Smart Criteria': b'opaque-rule', 'Playlist Items': [{'Track ID': 1}]},
            {'Playlist Persistent ID': 'system', 'Name': 'System', 'Master': True}]}
        self.destination = {'id': 'destination', 'cluster_id': 'cluster', 'entries': [
            {'sha256': 'a' * 64, 'track': {'id': 'dest-one', 'title': 'One', 'artist': 'Artist',
             'album': 'Album', 'duration': 120.5, 'track': 1}}]}
        self.write_inputs()

    def write_inputs(self):
        self.library.write_bytes(plistlib.dumps(self.source))
        self.catalog.write_text(json.dumps(self.destination))

    def edit(self, filename, changes, key):
        path = self.review / filename
        with path.open(encoding='utf-8-sig', newline='') as handle:
            reader = csv.DictReader(handle)
            fields = reader.fieldnames
            rows = list(reader)
        for row in rows:
            row.update(changes.get(row[key], {}))
        with path.open('w', encoding='utf-8-sig', newline='') as handle:
            writer = csv.DictWriter(handle, fieldnames=fields)
            writer.writeheader()
            writer.writerows(rows)

    def test_selection_requires_review_and_preserves_order_missing_items_and_duplicates(self):
        original = self.library.read_bytes(), self.catalog.read_bytes()
        summary = create_review(self.library, self.catalog, self.review)
        self.assertEqual(summary, {'playlists': 3, 'referenced_tracks': 2,
                                 'candidate': 1, 'ambiguous': 0, 'unmatched': 1})
        with self.assertRaisesRegex(ValueError, 'Select at least'):
            prepare(self.library, self.catalog, self.review, self.root / 'none.json')
        self.edit('playlists.csv', {'manual': {'decision': 'yes'}}, 'playlist_id')
        before = self.root / 'unreviewed.json'
        prepare(self.library, self.catalog, self.review, before)
        self.assertTrue(all(i['destination'] is None for p in json.loads(before.read_text())['playlists'] for i in p['items']))
        self.edit('tracks.csv', {'1': {'decision': 'accept'}}, 'source_track_id')
        output = self.root / 'prepared.json'
        result = prepare(self.library, self.catalog, self.review, output)
        self.assertEqual((result['resolved'], result['unresolved']), (2, 2))
        data = json.loads(output.read_text())
        self.assertEqual([p['source_playlist_id'] for p in data['playlists']], ['folder', 'manual'])
        items = data['playlists'][1]['items']
        self.assertEqual([i['source_track_id'] for i in items], ['1', '2', '1', '99'])
        self.assertEqual(len({i['id'] for i in items}), 4)
        self.assertEqual(items[0]['destination']['sha256'], 'a' * 64)
        self.assertIsNone(items[3]['source'])
        self.assertEqual((self.library.read_bytes(), self.catalog.read_bytes()), original)
        with self.assertRaises(FileExistsError):
            prepare(self.library, self.catalog, self.review, output)

    def test_folder_selection_excludes_deselected_children_and_retains_snapshot_definition(self):
        create_review(self.library, self.catalog, self.review)
        self.edit('playlists.csv', {'folder': {'decision': 'yes'}, 'manual': {'decision': 'no'}}, 'playlist_id')
        output = self.root / 'prepared.json'
        prepare(self.library, self.catalog, self.review, output)
        data = json.loads(output.read_text())
        self.assertEqual([p['source_playlist_id'] for p in data['playlists']], ['folder', 'smart'])
        self.assertEqual(data['playlists'][1]['kind'], 'snapshot')
        self.assertEqual(data['playlists'][1]['definition']['Smart Criteria'], 'b3BhcXVlLXJ1bGU=')

    def test_ambiguous_candidates_are_never_automatically_accepted(self):
        duplicate = json.loads(json.dumps(self.destination['entries'][0]))
        duplicate['track']['id'] = 'another'
        duplicate['sha256'] = 'b' * 64
        self.destination['entries'].append(duplicate)
        self.write_inputs()
        summary = create_review(self.library, self.catalog, self.review)
        self.assertEqual(summary['ambiguous'], 1)
        self.edit('playlists.csv', {'manual': {'decision': 'yes'}}, 'playlist_id')
        self.edit('tracks.csv', {'1': {'decision': 'accept', 'destination_track_id': 'unknown'}}, 'source_track_id')
        with self.assertRaisesRegex(ValueError, 'not a listed candidate'):
            prepare(self.library, self.catalog, self.review, self.root / 'bad.json')

    def test_changed_destination_requires_a_fresh_review(self):
        create_review(self.library, self.catalog, self.review)
        self.destination['entries'][0]['sha256'] = 'b' * 64
        self.write_inputs()
        with self.assertRaisesRegex(ValueError, 'changed'):
            prepare(self.library, self.catalog, self.review, self.root / 'bad.json')

    def test_server_audio_identity_resolves_to_a_distinct_logical_track(self):
        self.destination['organization'] = {
            'trackAliases': {'dest-one': 'logical-one'},
            'tracks': [{'id': 'logical-one', 'sha256': 'a' * 64}]}
        self.write_inputs()
        create_review(self.library, self.catalog, self.review)
        self.edit('playlists.csv', {'manual': {'decision': 'yes'}}, 'playlist_id')
        self.edit('tracks.csv', {'1': {'decision': 'accept'}}, 'source_track_id')
        output = self.root / 'prepared.json'
        prepare(self.library, self.catalog, self.review, output)
        item = json.loads(output.read_text())['playlists'][1]['items'][0]
        self.assertEqual(item['destination'], {'track_id': 'logical-one', 'sha256': 'a' * 64})

    def test_folder_cycles_and_entities_are_rejected(self):
        self.source['Playlists'][0]['Parent Persistent ID'] = 'folder'
        self.write_inputs()
        with self.assertRaisesRegex(ValueError, 'cycle'):
            create_review(self.library, self.catalog, self.review)
        self.library.write_text('<!DOCTYPE plist [<!ENTITY secret SYSTEM "file:///example">]><plist/>')
        with self.assertRaisesRegex(ValueError, 'entity'):
            create_review(self.library, self.catalog, self.review)

    def test_export_reads_a_real_server_schema_without_audio_or_writes(self):
        database = self.root / 'node.sqlite'
        with sqlite3.connect(database) as db:
            db.executescript('CREATE TABLE library (singleton INTEGER, id TEXT);'
                             'CREATE TABLE tracks (id TEXT, payload BLOB);'
                             'CREATE TABLE organization (singleton INTEGER, payload BLOB);'
                             'CREATE TABLE cluster_identity (singleton INTEGER, id TEXT);'
                             "INSERT INTO library VALUES (1, 'destination');"
                             "INSERT INTO cluster_identity VALUES (1, 'cluster');")
            entry = {**self.destination['entries'][0], 'artwork': 'not-exported'}
            db.execute('INSERT INTO tracks VALUES (?, ?)', ('dest-one', json.dumps(entry)))
        original = database.read_bytes()
        result = export_catalog(database)
        self.assertEqual(result['cluster_id'], 'cluster')
        self.assertEqual(result['entries'], self.destination['entries'])
        self.assertEqual(database.read_bytes(), original)
        with self.assertRaises(sqlite3.OperationalError):
            export_catalog(self.root / 'absent.sqlite')
        self.assertFalse((self.root / 'absent.sqlite').exists())


if __name__ == '__main__':
    unittest.main()
