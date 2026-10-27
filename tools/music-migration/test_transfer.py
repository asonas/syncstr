import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid

import transfer


class TransferTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / 'bundle'
        self.tid = str(uuid.uuid4())
        item = self.bundle / self.tid
        item.mkdir(parents=True)
        for name, data in {'audio.wav': b'fictional prepared transport bytes',
                           'entry.json': b'{}', 'organization.json': b'{}',
                           'source-evidence.json': b'{}'}.items():
            (item / name).write_bytes(data)
        self.row = {'id': self.tid, 'sha256': transfer.digest(item / 'audio.wav'),
                    'suffix': 'wav', 'size': (item / 'audio.wav').stat().st_size,
                    'asset': None, 'files': {p.name: transfer.digest(p) for p in item.iterdir()}}
        transfer.write_json(self.bundle / 'manifest.json', {'format_version': 1, 'tracks': [self.row]})
        self.destination = self.root / 'destination.json'
        transfer.write_json(self.destination, {'host': 'fixture-host', 'root': '/tmp/fixture-test',
            'image': 'sha256:' + 'a' * 64, 'mode': 'isolated-test', 'token': str(uuid.uuid4()), 'library_id': 'library'})
        self.run = self.root / 'run'
        self.actions = []
        self.objects = set()
        self.fail_reply = True

    def process(self, command, **kwargs):
        if command[0] == 'scp':
            return subprocess.CompletedProcess(command, 0)
        request = json.loads(kwargs['input'])
        action = request['action']
        self.actions.append(action)
        response = {}
        if action in ('import', 'verify'):
            if action == 'import':
                self.objects.add(request['record']['sha256'])
                if self.fail_reply:
                    self.fail_reply = False
                    return subprocess.CompletedProcess(command, 1, '', 'connection lost after commit')
            response = {'sha256': self.row['sha256'], 'size': self.row['size'],
                        'metadata': 'verified', 'artwork': 'missing'}
        return subprocess.CompletedProcess(command, 0, json.dumps(response), '')

    def test_lost_reply_does_not_mark_complete_and_resume_reverifies_receipts(self):
        with patch('transfer.subprocess.run', side_effect=self.process):
            with self.assertRaisesRegex(ValueError, 'connection lost'):
                transfer.migrate(self.bundle, self.destination, self.run)
            self.assertEqual(transfer.read_json(self.run / 'progress.json')['completed'], {})
            transfer.migrate(None, None, self.run, resume=True)
            self.assertEqual(len(transfer.read_json(self.run / 'progress.json')['completed']), 1)
            self.actions.clear()
            transfer.migrate(None, None, self.run, resume=True)
            self.assertEqual(self.actions, ['check', 'verify'])
            self.assertEqual(len(self.objects), 1)

    def test_resume_rejects_changed_destination_before_network_access(self):
        with patch('transfer.subprocess.run', side_effect=self.process):
            with self.assertRaises(ValueError):
                transfer.migrate(self.bundle, self.destination, self.run)
        destination = transfer.read_json(self.destination)
        destination['library_id'] = 'different-library'
        transfer.write_json(self.destination, destination)
        with patch('transfer.subprocess.run') as network:
            with self.assertRaisesRegex(ValueError, 'Destination or manifest changed'):
                transfer.migrate(None, None, self.run, resume=True)
            network.assert_not_called()

    def test_changed_staged_audio_is_rejected_before_network_access(self):
        (self.bundle / self.tid / 'audio.wav').write_bytes(b'changed')
        with patch('transfer.subprocess.run') as network:
            with self.assertRaisesRegex(ValueError, 'Prepared bundle changed'):
                transfer.migrate(self.bundle, self.destination, self.run)
            network.assert_not_called()

    def test_existing_library_requires_exact_approval_and_bound_bundle(self):
        destination = transfer.read_json(self.destination)
        destination.update(mode='existing-library', manifest_sha256=transfer.digest(self.bundle / 'manifest.json'))
        transfer.write_json(self.destination, destination)
        with patch('transfer.subprocess.run') as network:
            for approval in (None, 'another-library'):
                with self.assertRaisesRegex(ValueError, 'approve-existing-library'):
                    transfer.migrate(self.bundle, self.destination, self.run,
                                     approve_existing_library=approval)
            self.assertFalse(self.run.exists())
            manifest = transfer.read_json(self.bundle / 'manifest.json')
            manifest['tracks'][0]['source_id'] = 'changed-selection'
            transfer.write_json(self.bundle / 'manifest.json', manifest)
            with self.assertRaisesRegex(ValueError, 'bound selection'):
                transfer.migrate(self.bundle, self.destination, self.run,
                                 approve_existing_library='library')
            network.assert_not_called()

    def test_existing_library_resume_keeps_approval_and_verification(self):
        destination = transfer.read_json(self.destination)
        destination.update(mode='existing-library', manifest_sha256=transfer.digest(self.bundle / 'manifest.json'))
        transfer.write_json(self.destination, destination)
        with patch('transfer.subprocess.run', side_effect=self.process):
            with self.assertRaisesRegex(ValueError, 'connection lost'):
                transfer.migrate(self.bundle, self.destination, self.run,
                                 approve_existing_library='library')
            with self.assertRaisesRegex(ValueError, 'approve-existing-library'):
                transfer.migrate(None, None, self.run, resume=True)
            transfer.migrate(None, None, self.run, resume=True, approve_existing_library='library')
            self.actions.clear()
            transfer.migrate(None, None, self.run, resume=True, approve_existing_library='library')
            self.assertEqual(self.actions, ['check', 'verify'])


if __name__ == '__main__':
    unittest.main()
