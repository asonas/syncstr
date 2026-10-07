import argparse
import json
import pathlib
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description='Run a disposable two-device connectivity probe')
parser.add_argument('binary', type=pathlib.Path)
parser.add_argument('--mode', choices=['direct', 'auto', 'relay-only'], default='direct')
args = parser.parse_args()
binary = str(args.binary.resolve())

with tempfile.TemporaryDirectory(prefix='syncstr-probe-') as directory:
    root = pathlib.Path(directory)
    server, client = root / 'server', root / 'client'

    def run(state, *arguments):
        result = subprocess.run([binary, '--state', str(state), *map(str, arguments)],
                                capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        return result.stdout.strip()

    server_id, client_id = run(server, 'init'), run(client, 'init')
    run(server, 'pair', '--peer', client_id)
    run(client, 'pair', '--peer', server_id)
    address = root / 'address.json'
    with (root / 'listener.log').open('w+') as log:
        listener = subprocess.Popen([binary, '--state', str(server), 'listen', '--mode', args.mode,
                                     '--address-out', str(address)], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 25
            while not address.exists():
                if listener.poll() is not None or time.monotonic() > deadline:
                    log.seek(0)
                    raise RuntimeError('Listener failed: ' + log.read())
                time.sleep(0.05)
            report = json.loads(run(client, 'probe', '--mode', args.mode,
                                    '--peer', server_id, '--address', address))
            selected = [path['kind'] for path in report['paths_after'] if path['selected']]
            if args.mode == 'direct':
                assert selected == ['direct'], report
            elif args.mode == 'relay-only':
                assert selected == ['relay'], report
            assert report['bytes'] == 65536
            print(json.dumps({'mode': args.mode, 'report': report}))
        finally:
            listener.terminate()
            try:
                listener.wait(timeout=25)
            except subprocess.TimeoutExpired:
                listener.kill()
                listener.wait()
