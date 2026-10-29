"""Read-only source registration inventory and unaccepted server correspondence."""

import argparse
import base64
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile

from audit import local_path
from review import MAX_CATALOG, MAX_XML, candidate_tracks, digest, read_bounded


SCHEMA = 1
CHUNK = 1024 * 1024
PLACEHOLDER = 0x1000 | 0x40000 | 0x400000
METADATA = ('Name', 'Artist', 'Album', 'Album Artist', 'Total Time',
            'Track Number', 'Disc Number', 'Compilation')
EVIDENCE = ('Kind', 'Track Type', 'Purchased', 'Matched', 'Protected',
            'Apple Music', 'Cloud Status', 'iCloud Status', 'Purchase Date')


def json_value(value):
    if isinstance(value, bytes):
        return {'base64': base64.b64encode(value).decode('ascii')}
    if isinstance(value, datetime):
        return value.isoformat()
    raise TypeError(f'Unsupported plist value: {type(value).__name__}')


def safe_local(path):
    """Check each ancestor before following it or opening file contents."""
    path = Path(os.path.abspath(path))
    if not path.is_absolute() or str(path).startswith(('\\\\', '//')):
        raise ValueError('Remote or nonabsolute path is not allowed')
    if os.name == 'nt':
        import ctypes
        if ctypes.windll.kernel32.GetDriveTypeW(str(path.anchor)) != 3:
            raise ValueError('Only local fixed drives are inspected')
    for item in reversed((path, *path.parents)):
        info = item.lstat()
        attributes = getattr(info, 'st_file_attributes', 0)
        if attributes & PLACEHOLDER:
            raise ValueError('placeholder_not_read')
        if stat.S_ISLNK(info.st_mode) or attributes & 0x400:
            raise ValueError('reparse_point_not_followed')
    return path


def signature(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def observe_file(path):
    result = {'read_status': 'not_attempted', 'hash_status': 'not_attempted'}
    try:
        path = safe_local(path)
        before = path.stat()
        result.update(size=before.st_size, modified_ns=before.st_mtime_ns)
        if not stat.S_ISREG(before.st_mode):
            return {**result, 'status': 'not_file'}
        sha = hashlib.sha256()
        total = 0
        with path.open('rb') as handle:
            opened = os.fstat(handle.fileno())
            if signature(before) != signature(opened):
                return {**result, 'status': 'unstable', 'hash_status': 'unstable'}
            while block := handle.read(CHUNK):
                sha.update(block)
                total += len(block)
            after = os.fstat(handle.fileno())
        result['read_status'] = 'readable'
        if signature(before) != signature(after) or signature(before) != signature(path.stat()) or total != before.st_size:
            return {**result, 'status': 'unstable', 'hash_status': 'unstable'}
        return {**result, 'status': 'available', 'hash_status': 'complete', 'sha256': sha.hexdigest()}
    except FileNotFoundError:
        return {**result, 'status': 'missing'}
    except ValueError as error:
        return {**result, 'status': 'not_inspected', 'reason': str(error)}
    except OSError as error:
        return {**result, 'status': 'read_failed', 'read_status': 'failed',
                'hash_status': 'failed', 'error_code': error.errno}


def mappings(values):
    result = []
    for value in values:
        left, separator, right = value.partition('=')
        if not separator or not Path(left).is_absolute() or not Path(right).is_absolute():
            raise ValueError('Root mappings must be absolute OLD=NEW paths')
        pair = (Path(os.path.abspath(left)), safe_local(right))
        if any(pair[0] == old or pair[0] in old.parents or old in pair[0].parents for old, _ in result):
            raise ValueError('Ambiguous overlapping root mappings')
        result.append(pair)
    return result


def location_record(track, remaps):
    result = {'original_url': track.get('Location')}
    if 'Location' not in track:
        return {**result, 'status': 'no_location'}
    try:
        original = Path(os.path.abspath(local_path(track['Location'])))
        effective = original
        for old, new in remaps:
            if original == old or old in original.parents:
                effective = new / original.relative_to(old)
                result['root_mapping'] = {'from': str(old), 'to': str(new)}
        return {**result, 'status': 'resolved', 'decoded_path': str(original), 'effective_path': str(effective)}
    except (ValueError, UnicodeError, TypeError) as error:
        return {**result, 'status': 'invalid', 'reason': str(error)}


def output_path(path, protected):
    output = Path(os.path.abspath(path))
    safe_local(output.parent)
    for start in (Path(__file__).absolute().parent, Path.cwd()):
        protected.update(p for p in (start, *start.parents) if (p / '.git').exists())
    if any(output == root or root in output.parents for root in protected):
        raise ValueError('Output must be outside repositories, source libraries and media roots')
    if output.exists():
        raise FileExistsError('Output already exists')
    return output


def publish(output, report):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=output.parent,
                                         prefix='.inventory-', suffix='.partial', delete=False) as handle:
            temporary = Path(handle.name)
            json.dump(report, handle, ensure_ascii=False, default=json_value, allow_nan=False)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        # Hard-link publication is atomic and refuses an existing destination.
        os.link(temporary, output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def revision():
    result = subprocess.run(['git', '-C', str(Path(__file__).parent), 'rev-parse', 'HEAD'],
                            capture_output=True, text=True, check=True)
    return {'git_revision': result.stdout.strip(), 'implementation_sha256': {
        name: digest(Path(__file__).with_name(name).read_bytes())
        for name in ('inventory.py', 'audit.py', 'review.py')}}


def inventory(libraries, output, root_maps=(), limit=None):
    remaps = mappings(root_maps)
    sources, parsed, rows = [], [], []
    protected = {new for _, new in remaps}
    originals = []
    for source_index, filename in enumerate(libraries):
        path = safe_local(filename)
        raw = read_bounded(path, MAX_XML)
        library = plistlib.loads(raw)
        if not isinstance(library.get('Tracks'), dict):
            raise ValueError('XML Tracks must be a dictionary')
        originals.append((path, raw))
        parsed.append(library)
        protected.add(path.parent)
        sources.append({'index': source_index, 'path': str(path), 'sha256': digest(raw),
                        'library_persistent_id': library.get('Library Persistent ID'),
                        'application_version': library.get('Application Version')})
        if library.get('Music Folder'):
            folder = location_record({'Location': library['Music Folder']}, remaps)
            if folder['status'] == 'resolved':
                protected.add(Path(folder['effective_path']))
        for xml_id, track in library['Tracks'].items():
            location = location_record(track, remaps)
            if location['status'] == 'resolved':
                protected.add(Path(location['effective_path']).parent)
            rows.append({'row_id': f'{source_index}:{xml_id}', 'source_index': source_index,
                         'xml_dictionary_key': xml_id, 'xml_track_id': track.get('Track ID'),
                         'library_persistent_id': library.get('Library Persistent ID'),
                         'track_persistent_id': track.get('Persistent ID'),
                         'metadata': {k: track[k] for k in METADATA if k in track},
                         'provenance': {k: track[k] for k in EVIDENCE if k in track},
                         'eligibility': 'unresolved', 'playability': 'not_tested',
                         'protection': 'flagged' if track.get('Protected') is True or
                         str(track.get('Location', '')).lower().endswith('.m4p') else 'unknown',
                         'location': location})
    output = output_path(output, protected)
    library_counts = Counter(s['library_persistent_id'] for s in sources)
    keys = Counter((r['library_persistent_id'], r['track_persistent_id']) for r in rows)
    hashed = 0
    for index, row in enumerate(rows):
        key = (row['library_persistent_id'], row['track_persistent_id'])
        reasons = []
        if any(not isinstance(v, str) or not v.strip() for v in key):
            reasons.append('missing_or_invalid_persistent_id')
        if library_counts[key[0]] > 1:
            reasons.append('duplicate_or_conflicting_library_id')
        if keys[key] > 1:
            reasons.append('duplicate_source_key')
        row['identity'] = {'status': 'invalid' if reasons else 'valid', 'reasons': reasons,
                           'proposed_key': list(key), 'stable_key': None if reasons else list(key)}
        location = row['location']
        if location['status'] != 'resolved':
            row['file'] = {'status': location['status'], 'read_status': 'not_attempted', 'hash_status': 'not_attempted'}
        elif limit is not None and hashed >= limit:
            row['file'] = {'status': 'not_sampled', 'read_status': 'not_attempted', 'hash_status': 'not_attempted'}
        else:
            row['file'] = observe_file(location['effective_path'])
            hashed += 1
        if (index + 1) % 100 == 0 or index + 1 == len(rows):
            print(f'Inspected {index + 1}/{len(rows)} registrations; attempted {hashed} files', file=sys.stderr)
    playlists = []
    for source_index, library in enumerate(parsed):
        for playlist in library.get('Playlists', []):
            items = []
            for position, item in enumerate(playlist.get('Playlist Items', []), 1):
                xml_id = str(item.get('Track ID'))
                exists = xml_id in library['Tracks']
                items.append({'position': position, 'xml_track_id': item.get('Track ID'),
                              'row_id': f'{source_index}:{xml_id}' if exists else None,
                              'resolved_in_xml': exists})
            playlists.append({'source_index': source_index, 'metadata': {
                k: v for k, v in playlist.items() if k != 'Playlist Items'}, 'items': items})
    unchanged = all(read_bounded(safe_local(path), MAX_XML) == raw for path, raw in originals)
    if not unchanged:
        raise ValueError('XML changed during inventory; no completed report published')
    summary = {'registrations': len(rows), 'invalid_identities': sum(r['identity']['status'] == 'invalid' for r in rows),
               'file_status': dict(Counter(r['file']['status'] for r in rows)),
               'protected_entries': sum(r['protection'] == 'flagged' for r in rows),
               'broken_playlist_references': sum(not i['resolved_in_xml'] for p in playlists for i in p['items'])}
    report = {'schema_version': SCHEMA, 'kind': 'source_inventory', 'complete': True,
              'created_at': datetime.now(timezone.utc).isoformat(), 'tool': revision(),
              'sources': sources, 'tracks': rows, 'playlists': playlists, 'summary': summary,
              'protected_output_roots': sorted(str(p) for p in protected),
              'xml_unchanged_at_end': True, 'file_attempt_limit': limit,
              'limitations': ['Stat and XML checks detect ordinary concurrent changes, not an atomic snapshot.',
                              'Protection, ownership eligibility and playback availability are separate facts.']}
    publish(output, report)
    return summary


def correspondence(inventory_path, catalog_path, output):
    inventory_path, catalog_path = safe_local(inventory_path), safe_local(catalog_path)
    raw = read_bounded(inventory_path, 256 * 1024 * 1024)
    source = json.loads(raw)
    if source.get('schema_version') != SCHEMA or source.get('kind') != 'source_inventory' or source.get('complete') is not True:
        raise ValueError('A complete version-1 inventory is required')
    catalog_raw = read_bounded(catalog_path, MAX_CATALOG)
    catalog = json.loads(catalog_raw)
    if not catalog.get('id'):
        raise ValueError('Destination library ID is required')
    entries = catalog['entries']
    if len(entries) > 100000 or len({e['track']['id'] for e in entries}) != len(entries):
        raise ValueError('Invalid destination identities or size')
    for entry in entries:
        value = entry['sha256']
        if len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
            raise ValueError('Invalid destination hash')
    # Preserve invalid source rows while reusing the existing metadata criteria.
    metadata = candidate_tracks({'Tracks': {r['row_id']: r['metadata'] for r in source['tracks']}}, catalog)
    aliases = (catalog.get('organization') or {}).get('trackAliases') or {}

    def canonical(identity):
        seen = set()
        while identity in aliases:
            if identity in seen:
                raise ValueError('Destination alias cycle')
            seen.add(identity)
            identity = aliases[identity]
        return identity

    by_hash = defaultdict(list)
    for entry in entries:
        by_hash[entry['sha256']].append(entry)
    rows, shared = [], defaultdict(list)
    fields = {'Name': 'title', 'Artist': 'artist', 'Album': 'album', 'Album Artist': 'albumArtist',
              'Total Time': 'duration', 'Track Number': 'track', 'Disc Number': 'discNumber', 'Compilation': 'compilation'}
    for row in source['tracks']:
        sha = row['file'].get('sha256') if row['file']['hash_status'] == 'complete' else None
        exact = by_hash.get(sha, [])
        suggestions = {(c['track_id'], c['sha256']) for c in metadata[row['row_id']]['candidates']}
        matches = exact or [e for e in entries if (canonical(e['track']['id']), e['sha256']) in suggestions]
        candidates = []
        for entry in matches:
            identity = canonical(entry['track']['id'])
            comparison = {}
            for left, right in fields.items():
                before, after = row['metadata'].get(left), entry['track'].get(right)
                target_value = after * 1000 if left == 'Total Time' and isinstance(after, (int, float)) else after
                comparison[left] = {'source': before, 'destination': after,
                                    'comparison': 'missing' if before is None or after is None else
                                    'equal' if before == target_value else 'different'}
            candidates.append({'entry_track_id': entry['track']['id'], 'canonical_track_id': identity,
                               'aliases': sorted(a for a in aliases if canonical(a) == identity),
                               'sha256': entry['sha256'], 'basis': 'exact_bytes' if exact else 'metadata',
                               'fields': comparison})
            shared[(identity, entry['sha256'])].append(row['row_id'])
        status = ('source_identity_invalid' if row['identity']['status'] != 'valid' else
                  'source_unavailable' if row['file']['hash_status'] != 'complete' else
                  'exact_bytes_candidate' if exact else 'metadata_candidate' if candidates else 'unmatched')
        rows.append({'row_id': row['row_id'], 'source_key': row['identity']['stable_key'], 'status': status,
                     'source_identity': row['identity'], 'source_file_status': row['file']['status'],
                     'candidates': candidates, 'decision': None, 'flags': []})
    shared_rows = {row_id for ids in shared.values() if len(set(ids)) > 1 for row_id in ids}
    for row in rows:
        if row['row_id'] in shared_rows:
            row['flags'].append('shared_audio_requires_distinct_tracks')
    protected = {Path(s['path']).parent for s in source['sources']}
    protected.update(Path(p) for p in source['protected_output_roots'])
    protected.update(Path(r['location']['effective_path']).parent for r in source['tracks'] if r['location']['status'] == 'resolved')
    destination = output_path(output, protected)
    if read_bounded(catalog_path, MAX_CATALOG) != catalog_raw or read_bounded(inventory_path, 256 * 1024 * 1024) != raw:
        raise ValueError('Review inputs changed; no report published')
    summary = {'registrations': len(rows), 'status': dict(Counter(r['status'] for r in rows)),
               'shared_audio_requires_distinct_tracks': len(shared_rows)}
    publish(destination, {'schema_version': SCHEMA, 'kind': 'source_correspondence_review', 'complete': True,
                         'created_at': datetime.now(timezone.utc).isoformat(), 'tool': revision(),
                         'inventory_sha256': digest(raw), 'destination_library_id': catalog['id'],
                         'destination_cluster_id': catalog.get('cluster_id'), 'catalog_sha256': digest(catalog_raw),
                         'tracks': rows, 'summary': summary,
                         'limitations': ['Metadata fallback requires title/artist/album NFC equality, duration within 2 seconds, and supplied track/disc numbers.',
                                         'Exact bytes do not establish logical track identity; every candidate requires review.',
                                         'Catalog freshness is established by obtaining a new server export, not by this offline tool.']})
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    scan = commands.add_parser('inventory')
    scan.add_argument('--library', type=Path, action='append', required=True)
    scan.add_argument('--root-map', action='append', default=[])
    scan.add_argument('--file-limit', type=int, help='Attempt only this many files; retain all XML registrations')
    scan.add_argument('--output', type=Path, required=True)
    review = commands.add_parser('review')
    review.add_argument('--inventory', type=Path, required=True)
    review.add_argument('--catalog', type=Path, required=True)
    review.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'inventory':
            if args.file_limit is not None and args.file_limit < 0:
                raise ValueError('File limit must be nonnegative')
            summary = inventory(args.library, args.output, args.root_map, args.file_limit)
        else:
            summary = correspondence(args.inventory, args.catalog, args.output)
        print(json.dumps(summary))
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, f'{type(error).__name__}: {error}\n')


if __name__ == '__main__':
    main()
