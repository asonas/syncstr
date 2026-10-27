import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import shutil
import wave


SCRIPT = Path(__file__).with_name('migration.py')


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.library = self.source / 'Library.xml'
        self.output = self.root / 'run'

    def track(self, number, **fields):
        return {'Persistent ID': f'{number:016X}', 'Name': f'Track {number}',
                'Kind': 'MPEG audio file', 'Track Type': 'File', **fields}

    def write_library(self, tracks):
        self.library.write_bytes(plistlib.dumps({
            'Library Persistent ID': '0123456789ABCDEF',
            'Music Folder': self.source.as_uri() + '/',
            'Tracks': {str(n): track for n, track in enumerate(tracks)},
        }))

    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args],
                              capture_output=True, text=True, encoding='utf-8')

    def scan(self, output=None):
        return self.run_cli('inventory', '--library', str(self.library),
                            '--output', str(output or self.output))

    def test_preview_retains_evidence_without_claiming_transfer_eligibility(self):
        audio = self.source / 'sample #1 音源.mp3'
        audio.write_bytes(b'fictional file readability fixture')
        self.write_library([
            self.track(1, Purchased=True, Location=audio.as_uri(), Album='Library album',
                       Compilation=True, Genre='ロック', **{'Disc Number': 2, 'Sort Album': 'Sorted album',
                                            'Play Count': 99, 'Rating': 80}),
            self.track(2, Matched=True, **{'Track Type': 'Remote'}),
            self.track(3, **{'Apple Music': True, 'Purchased': True}),
            self.track(4, Kind='Matched AAC audio file'),
            self.track(5, Purchased=True, Protected=True),
            self.track(6, Purchased=True, Location=(self.source / 'missing.mp3').as_uri()),
            self.track(7, Purchased=True, **{'Has Video': True}),
            self.track(8, Purchased='true'),
        ])
        original_xml = self.library.read_bytes()
        original_audio = hashlib.sha256(audio.read_bytes()).hexdigest()
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads((self.output / 'inventory.json').read_text(encoding='utf-8'))
        self.assertEqual(data['summary']['decisions'], {'candidate': 2, 'excluded': 2, 'review': 4})
        self.assertEqual([r['reason'] for r in data['tracks']], [
            'ownership_evidenced', 'ownership_evidenced', 'subscription',
            'ownership_unresolved', 'protected', 'missing', 'not_audio', 'invalid_evidence'])
        first = data['tracks'][0]
        self.assertEqual(first['source_id'], '0123456789ABCDEF:0000000000000001')
        self.assertEqual(first['availability']['path'], str(audio))
        self.assertEqual(first['source_metadata']['Album'], 'Library album')
        self.assertEqual(first['source_metadata']['Disc Number'], 2)
        self.assertNotIn('Play Count', first['source_metadata'])
        self.assertNotIn('Rating', first['source_metadata'])
        self.assertEqual(first['artwork']['status'], 'not_checked_with_com')
        self.assertEqual(first['audio_verification'], 'not_verified')
        self.assertEqual(data['tracks'][1]['availability']['status'], 'no_location')
        self.assertEqual(self.library.read_bytes(), original_xml)
        self.assertEqual(hashlib.sha256(audio.read_bytes()).hexdigest(), original_audio)
        preview = self.run_cli('preview', '--inventory', str(self.output / 'inventory.json'),
                               '--status', 'candidate', '--limit', '1')
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertIn('Showing 1 of 2 records (candidate)', preview.stdout)
        self.assertIn('Library album', preview.stdout)
        self.assertIn('ロック', preview.stdout)
        self.assertNotIn('Track 3', preview.stdout)

    def test_output_never_overwrites_existing_runs_or_writes_into_source(self):
        self.write_library([self.track(1)])
        original = self.library.read_bytes()
        result = self.scan(self.source / 'report')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.source / 'report').exists())
        self.output.mkdir()
        marker = self.output / 'inventory.json'
        marker.write_text('keep', encoding='utf-8')
        self.assertNotEqual(self.scan().returncode, 0)
        self.assertEqual(marker.read_text(), 'keep')
        self.assertEqual(self.library.read_bytes(), original)

    def test_duplicate_source_identity_fails_without_output(self):
        self.write_library([self.track(1), self.track(1, Name='Other recording')])
        result = self.scan()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Duplicate track Persistent ID', result.stderr)
        self.assertFalse(self.output.exists())

    def test_two_source_records_for_one_file_require_review(self):
        audio = self.source / 'shared.mp3'
        audio.write_bytes(b'shared fixture')
        self.write_library([self.track(1, Purchased=True, Location=audio.as_uri()),
                            self.track(2, Matched=True, Location=audio.as_uri())])
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads((self.output / 'inventory.json').read_text(encoding='utf-8'))
        self.assertEqual(data['summary']['reasons'], {'duplicate_location': 2})
        self.assertEqual(data['summary']['decisions'], {'review': 2})
        self.assertEqual(len(data['tracks']), 2)

    @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'FFmpeg required for audio preparation')
    def test_prepare_retains_library_precedence_and_missing_artwork_without_changing_audio(self):
        audio = self.source / 'song.wav'
        with wave.open(str(audio), 'wb') as stream:
            stream.setnchannels(1)
            stream.setsampwidth(2)
            stream.setframerate(8000)
            stream.writeframes(b'\x00\x00' * 8000)
        checksum = hashlib.sha256(audio.read_bytes()).hexdigest()
        self.write_library([self.track(1, Purchased=True, Location=audio.as_uri(),
                                      Album='Reviewed album', Composer='Composer', **{'Disc Number': 2})])
        self.assertEqual(self.scan().returncode, 0)
        selection = self.root / 'selection.json'
        selection.write_text(json.dumps({'format_version': 1,
            'library_persistent_id': '0123456789ABCDEF', 'tracks': [{
                'source_id': '0123456789ABCDEF:0000000000000001', 'audio_sha256': checksum}]}))
        bundle = self.root / 'bundle'
        result = self.run_cli('prepare', '--inventory', str(self.output / 'inventory.json'),
                              '--selection', str(selection), '--output', str(bundle))
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((bundle / 'manifest.json').read_text())
        row = manifest['tracks'][0]
        entry = json.loads((bundle / row['id'] / 'entry.json').read_text())
        evidence = json.loads((bundle / row['id'] / 'source-evidence.json').read_text())
        self.assertEqual(entry['track']['album'], 'Reviewed album')
        self.assertEqual(entry['track']['discNumber'], 2)
        self.assertEqual(evidence['library_metadata']['Composer'], 'Composer')
        self.assertEqual(row['artwork_status'], 'missing')
        self.assertEqual(hashlib.sha256(audio.read_bytes()).hexdigest(), checksum)
        self.assertEqual(hashlib.sha256((bundle / row['id'] / 'audio.wav').read_bytes()).hexdigest(), checksum)
        corrupt_image = self.root / 'corrupt.jpg'
        corrupt_image.write_bytes(b'not an image')
        picked = json.loads(selection.read_text())
        picked['tracks'][0]['artwork'] = {'path': str(corrupt_image),
            'sha256': hashlib.sha256(corrupt_image.read_bytes()).hexdigest()}
        selection.write_text(json.dumps(picked))
        partial = self.root / 'partial-artwork'
        result = self.run_cli('prepare', '--inventory', str(self.output / 'inventory.json'),
                              '--selection', str(selection), '--output', str(partial))
        self.assertEqual(result.returncode, 0, result.stderr)
        missing = json.loads((partial / 'manifest.json').read_text())['tracks'][0]
        self.assertEqual(missing['artwork_status'], 'unavailable')
        self.assertIsNone(missing['asset'])

    @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'FFmpeg required')
    def test_prepare_keeps_unset_albums_empty_and_separate(self):
        tracks, picks = [], []
        for number in (1, 2):
            audio = self.source / f'{number}.wav'
            with wave.open(str(audio), 'wb') as stream:
                stream.setnchannels(1)
                stream.setsampwidth(2)
                stream.setframerate(8000)
                stream.writeframes(bytes([number, 0]) * 8000)
            fields = {'Album': ''} if number == 2 else {}
            tracks.append(self.track(number, Purchased=True, Location=audio.as_uri(), Artist='Same artist', **fields))
            picks.append({'source_id': f'0123456789ABCDEF:{number:016X}',
                          'audio_sha256': hashlib.sha256(audio.read_bytes()).hexdigest()})
        self.write_library(tracks)
        self.assertEqual(self.scan().returncode, 0)
        selection = self.root / 'selection.json'
        selection.write_text(json.dumps({'format_version': 1, 'library_persistent_id': '0123456789ABCDEF', 'tracks': picks}))
        bundle = self.root / 'bundle'
        result = self.run_cli('prepare', '--inventory', str(self.output / 'inventory.json'), '--selection', str(selection), '--output', str(bundle))
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = json.loads((bundle / 'manifest.json').read_text())['tracks']
        album_ids = []
        for row in rows:
            entry = json.loads((bundle / row['id'] / 'entry.json').read_text())
            self.assertEqual(entry['track']['album'], '')
            self.assertFalse(entry['importedAlbum'].get('title'))
            album_ids.append(entry['track']['albumId'])
            original = self.source / ('1.wav' if row['source_id'].endswith('1') else '2.wav')
            self.assertEqual(hashlib.sha256(original.read_bytes()).hexdigest(), row['sha256'])
        self.assertEqual(len(set(album_ids)), 2)

    def test_prepare_rejects_subscription_even_with_an_uploaded_observation(self):
        audio = self.source / 'subscription.mp3'
        audio.write_bytes(b'not an eligible recording')
        self.write_library([self.track(1, Location=audio.as_uri(), **{'Apple Music': True})])
        self.assertEqual(self.scan().returncode, 0)
        selection = self.root / 'selection.json'
        selection.write_text(json.dumps({'format_version': 1,
            'library_persistent_id': '0123456789ABCDEF', 'tracks': [{
                'source_id': '0123456789ABCDEF:0000000000000001',
                'audio_sha256': hashlib.sha256(audio.read_bytes()).hexdigest(),
                'cloud_observation': {'status': 'uploaded', 'observed_at': '2026-01-01', 'method': 'UI'}}]}))
        bundle = self.root / 'bundle'
        result = self.run_cli('prepare', '--inventory', str(self.output / 'inventory.json'),
                              '--selection', str(selection), '--output', str(bundle))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('subscription', result.stderr)
        self.assertFalse(bundle.exists())


if __name__ == '__main__':
    unittest.main()
