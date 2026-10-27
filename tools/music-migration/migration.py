"""Review and migrate local iTunes audio into an isolated NAS test library."""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import sys
import subprocess
from urllib.parse import unquote, urlsplit


METADATA_FIELDS = (
    'Name', 'Artist', 'Album', 'Album Artist', 'Composer', 'Year', 'Genre',
    'Track Number', 'Track Count', 'Disc Number', 'Disc Count', 'Compilation',
    'Sort Name', 'Sort Artist', 'Sort Album', 'Sort Album Artist', 'Sort Composer',
)
EVIDENCE_FIELDS = (
    'Kind', 'Track Type', 'Apple Music', 'Purchased', 'Matched', 'Protected',
    'Playlist Only', 'Has Video', 'Movie', 'Artwork Count', 'Size',
)
FLAGS = ('Apple Music', 'Purchased', 'Matched', 'Protected', 'Playlist Only',
         'Has Video', 'Movie')


def persistent_id(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9A-Fa-f]{16}', value):
        raise ValueError('The library and every track need a 16-digit Persistent ID')
    return value.upper()


def file_path(location):
    if not isinstance(location, str):
        raise ValueError('Location must be a file URI')
    uri = urlsplit(location)
    if uri.scheme != 'file' or uri.query or uri.fragment:
        raise ValueError('Location must be a file URI without query or fragment')
    path = unquote(uri.path, errors='strict')
    if uri.netloc and uri.netloc.lower() != 'localhost':
        path = '//' + uri.netloc + path
    elif re.match(r'^/[A-Za-z]:/', path):
        path = path[1:]
    result = Path(path)
    if not result.is_absolute() or '\x00' in path:
        raise ValueError('Location must identify an absolute file path')
    return result


def inspect_file(track):
    if 'Location' not in track:
        return {'status': 'no_location'}
    try:
        path = file_path(track['Location'])
    except (ValueError, UnicodeError) as error:
        return {'status': 'invalid_location', 'detail': str(error)}
    result = {'path': str(path), 'suffix': path.suffix.lower()}
    try:
        with path.open('rb') as audio:
            stat = os.fstat(audio.fileno())
            readable = bool(audio.read(1))
        result.update(status='readable' if readable else 'empty', size=stat.st_size)
    except FileNotFoundError:
        result['status'] = 'missing'
    except OSError as error:
        result.update(status='unreadable', error_code=error.errno)
    return result


def classify(track, availability):
    kind = str(track.get('Kind', ''))
    if track.get('Apple Music') is True or 'apple music' in kind.casefold():
        return 'excluded', 'subscription'
    if (track.get('Has Video') is True or track.get('Movie') is True
            or 'video' in kind.casefold() or 'ビデオ' in kind):
        return 'excluded', 'not_audio'
    if any(key in track and type(track[key]) is not bool for key in FLAGS):
        return 'review', 'invalid_evidence'
    if track.get('Protected') is True or availability.get('suffix') == '.m4p':
        return 'review', 'protected'
    if track.get('Playlist Only') is True:
        return 'review', 'playlist_only'
    if availability['status'] in ('missing', 'unreadable', 'empty', 'invalid_location'):
        return 'review', availability['status']
    if track.get('Purchased') is True or track.get('Matched') is True:
        return 'candidate', 'ownership_evidenced'
    return 'review', 'ownership_unresolved'


def inventory(library_path, output):
    library_path = library_path.resolve()
    raw = library_path.read_bytes()
    library = plistlib.loads(raw)
    library_id = persistent_id(library.get('Library Persistent ID'))
    source_tracks = library.get('Tracks')
    if not isinstance(source_tracks, dict):
        raise ValueError('The XML must contain a Tracks dictionary')
    output = output.resolve()
    if output.exists():
        raise ValueError('Output must be a new directory; existing runs are never overwritten')
    protected_directories = {library_path.parent}
    if library.get('Music Folder'):
        protected_directories.add(file_path(library['Music Folder']).resolve())
    records = []
    seen = set()
    for track in source_tracks.values():
        track_id = persistent_id(track.get('Persistent ID'))
        if track_id in seen:
            raise ValueError('Duplicate track Persistent ID; source correspondence is ambiguous')
        seen.add(track_id)
        availability = inspect_file(track)
        if 'path' in availability:
            protected_directories.add(Path(availability['path']).resolve().parent)
        decision, reason = classify(track, availability)
        records.append({
            'source_id': f'{library_id}:{track_id}',
            'persistent_id': track_id,
            'decision': decision,
            'reason': reason,
            'source_metadata': {k: track[k] for k in METADATA_FIELDS if k in track},
            'source_evidence': {k: track[k] for k in EVIDENCE_FIELDS if k in track},
            'availability': availability,
            'audio_verification': 'not_verified',
            'embedded_metadata': {'status': 'not_read'},
            'artwork': {'status': 'not_checked_with_com'},
        })
    if any(output == parent or parent in output.parents for parent in protected_directories):
        raise ValueError('Output must be outside the source library and media directories')
    locations = Counter(os.path.normcase(r['availability']['path']) for r in records
                        if 'path' in r['availability'])
    for record in records:
        path = record['availability'].get('path')
        if path and locations[os.path.normcase(path)] > 1:
            record['duplicate_location'] = True
            if record['decision'] != 'excluded':
                record.update(decision='review', reason='duplicate_location')
    summary = {
        'records': len(records),
        'decisions': dict(Counter(r['decision'] for r in records)),
        'reasons': dict(Counter(r['reason'] for r in records)),
        'availability': dict(Counter(r['availability']['status'] for r in records)),
        'candidate_availability': dict(Counter(r['availability']['status'] for r in records
                                              if r['decision'] == 'candidate')),
    }
    snapshot_hash = hashlib.sha256(raw).hexdigest()
    try:
        current_hash = hashlib.sha256(library_path.read_bytes()).hexdigest()
        snapshot_current = current_hash == snapshot_hash
    except OSError:
        snapshot_current = None
    manifest = {
        'format_version': 1,
        'created_at': datetime.now(timezone.utc).isoformat(),
        'source': {
            'library_persistent_id': library_id,
            'xml_path': str(library_path),
            'xml_sha256': snapshot_hash,
            'xml_date': str(library.get('Date', '')),
            'application_version': library.get('Application Version'),
            'unchanged_at_end': snapshot_current,
        },
        'summary': summary,
        'tracks': records,
    }
    # Persist only migration fields, not raw XML containing playback history.
    encoded = json.dumps(manifest, ensure_ascii=False, indent=2)
    output.mkdir(parents=True, exist_ok=False)
    (output / 'inventory.json').write_text(encoded + '\n', encoding='utf-8', newline='\n')
    return manifest


def show_summary(manifest):
    counts = manifest['summary']
    print(f"Records: {counts['records']}")
    for decision in ('candidate', 'excluded', 'review'):
        print(f"{decision}: {counts['decisions'].get(decision, 0)}")
    print('Candidate means ownership-evidenced, not verified for transfer.')
    for reason, count in sorted(counts['reasons'].items()):
        print(f'  {reason}: {count}')
    print('Availability: ' + ', '.join(f'{k}={v}' for k, v in sorted(counts['availability'].items())))
    if manifest['source']['unchanged_at_end'] is not True:
        print('The source changed or could not be rechecked; use a new inventory before import.')


def preview(path, status, limit):
    manifest = json.loads(path.read_text(encoding='utf-8'))
    if manifest.get('format_version') != 1:
        raise ValueError('Unsupported inventory format version')
    show_summary(manifest)
    tracks = [r for r in manifest['tracks'] if status == 'all' or r['decision'] == status]
    print(f'\nShowing {min(limit, len(tracks))} of {len(tracks)} records ({status}):')
    for record in tracks[:limit]:
        metadata = record['source_metadata']
        print(json.dumps({
            'source_id': record['source_id'],
            'decision': record['decision'],
            'reason': record['reason'],
            'availability': record['availability']['status'],
            **metadata,
        }, ensure_ascii=False))
    print('Album names are source evidence; this preview does not assign album membership.')


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    scan = commands.add_parser('inventory', help='Read XML and check file readability without changing the library')
    scan.add_argument('--library', required=True, type=Path)
    scan.add_argument('--output', required=True, type=Path, help='New private directory outside source media')
    view = commands.add_parser('preview', help='Show inventory counts and selected source records')
    view.add_argument('--inventory', required=True, type=Path)
    view.add_argument('--status', choices=('all', 'candidate', 'excluded', 'review'), default='all')
    view.add_argument('--limit', type=int, default=20)
    prepare = commands.add_parser('prepare', help='Package an explicitly reviewed selection')
    prepare.add_argument('--inventory', required=True, type=Path)
    prepare.add_argument('--selection', required=True, type=Path)
    prepare.add_argument('--output', required=True, type=Path)
    prepare.add_argument('--ffmpeg', default='ffmpeg')
    prepare.add_argument('--ffprobe', default='ffprobe')
    init = commands.add_parser('init-test', help='Create a new independent NAS library')
    init.add_argument('--host', required=True)
    init.add_argument('--root', required=True)
    init.add_argument('--image', required=True)
    init.add_argument('--output', required=True, type=Path)
    existing = commands.add_parser('bind-existing', help='Bind a stopped existing library to a reviewed bundle')
    existing.add_argument('--host', required=True)
    existing.add_argument('--root', required=True)
    existing.add_argument('--image', required=True)
    existing.add_argument('--library-id', required=True)
    existing.add_argument('--bundle', required=True, type=Path)
    existing.add_argument('--output', required=True, type=Path)
    existing.add_argument('--initialize-cluster', action='store_true')
    transfer = commands.add_parser('import', help='Import a prepared selection and persist verified receipts')
    transfer.add_argument('--bundle', required=True, type=Path)
    transfer.add_argument('--destination', required=True, type=Path)
    transfer.add_argument('--run', required=True, type=Path)
    transfer.add_argument('--approve-existing-library')
    resume = commands.add_parser('resume', help='Reverify completed items and retry unfinished items')
    resume.add_argument('--run', required=True, type=Path)
    resume.add_argument('--approve-existing-library')
    args = parser.parse_args()
    try:
        if args.command == 'inventory':
            show_summary(inventory(args.library, args.output))
        elif args.command == 'preview':
            if args.limit < 0:
                raise ValueError('--limit must be nonnegative')
            preview(args.inventory, args.status, args.limit)
        elif args.command == 'prepare':
            from prepare import prepare
            prepare(args.inventory, args.selection, args.output, args.ffmpeg, args.ffprobe)
        elif args.command == 'init-test':
            from transfer import initialize
            initialize(args.host, args.root, args.image, args.output)
        elif args.command == 'bind-existing':
            from transfer import bind_existing
            bind_existing(args.host, args.root, args.image, args.library_id, args.bundle,
                          args.output, args.initialize_cluster)
        else:
            from transfer import migrate
            if args.command == 'import':
                migrate(args.bundle, args.destination, args.run,
                        approve_existing_library=args.approve_existing_library)
            else:
                migrate(None, None, args.run, resume=True,
                        approve_existing_library=args.approve_existing_library)
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        parser.exit(1, f'Error: {error}\n')


if __name__ == '__main__':
    main()
