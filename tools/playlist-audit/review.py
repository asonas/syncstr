"""Prepare a selective playlist migration against a Syncstr server catalog."""

import argparse
import base64
import csv
import hashlib
import json
from pathlib import Path
import plistlib
import unicodedata


MAX_XML = 32 * 1024 * 1024
MAX_CATALOG = 64 * 1024 * 1024


def read_bounded(path, limit):
    with Path(path).open('rb') as handle:
        data = handle.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f'Input exceeds {limit} bytes')
    return data


def digest(data):
    return hashlib.sha256(data).hexdigest()


def normalized(value):
    return unicodedata.normalize('NFC', value or '').strip()


def source_inputs(library_path, catalog_path):
    raw = read_bounded(library_path, MAX_XML)
    # iTunes uses a public plist DOCTYPE; custom entities are not needed.
    xml = raw.decode('utf-8-sig')
    if '<!ENTITY' in xml.upper():
        raise ValueError('XML entity declarations are not supported')
    library = plistlib.loads(raw)
    catalog_raw = read_bounded(catalog_path, MAX_CATALOG)
    catalog = json.loads(catalog_raw)
    if not library.get('Library Persistent ID') or not catalog.get('id'):
        raise ValueError('Both library identities are required')
    if len(library['Tracks']) > 100000 or len(library['Playlists']) > 10000:
        raise ValueError('Source library exceeds migration limits')
    entries = catalog['entries']
    if len(entries) > 100000 or len({e['track']['id'] for e in entries}) != len(entries):
        raise ValueError('Invalid destination catalog identities or size')
    for entry in entries:
        value = entry['sha256']
        if len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
            raise ValueError('Invalid destination content hash')
    return library, catalog, {
        'source_sha256': digest(raw), 'catalog_sha256': digest(catalog_raw),
        'source_library_id': library['Library Persistent ID'],
        'destination_library_id': catalog['id'],
        'destination_cluster_id': catalog.get('cluster_id'),
    }


def playlist_records(library):
    records = {}
    for source in library['Playlists']:
        identity = source.get('Playlist Persistent ID')
        if not identity or identity in records:
            raise ValueError('Missing or duplicate playlist persistent identity')
        kind = ('folder' if source.get('Folder') is True else
                'system' if source.get('Master') is True or 'Distinguished Kind' in source else
                'snapshot' if any(k in source for k in ('Smart Info', 'Smart Criteria')) else 'manual')
        records[identity] = {
            'id': identity, 'name': source.get('Name', ''), 'kind': kind,
            'parent': source.get('Parent Persistent ID'),
            'items': [str(item.get('Track ID')) for item in source.get('Playlist Items', [])]
                     if kind not in ('folder', 'system') else [],
            'definition': {k: base64.b64encode(source[k]).decode('ascii')
                           for k in ('Smart Info', 'Smart Criteria') if k in source},
        }
    if sum(len(record['items']) for record in records.values()) > 1000000:
        raise ValueError('Too many playlist occurrences')
    for record in records.values():
        ancestors = []
        parent = record['parent']
        while parent:
            if parent in ancestors or parent == record['id']:
                raise ValueError('Playlist folder cycle')
            if parent not in records or records[parent]['kind'] != 'folder':
                raise ValueError('Missing or non-folder playlist parent')
            ancestors.append(parent)
            parent = records[parent]['parent']
        record['ancestors'] = list(reversed(ancestors))
        record['path'] = ' / '.join(records[i]['name'] for i in record['ancestors'] + [record['id']])
    return records


def candidate_tracks(library, catalog):
    aliases = (catalog.get('organization') or {}).get('trackAliases') or {}
    entries = {entry['track']['id']: entry for entry in catalog['entries']}
    known = set(entries) | {t['id'] for t in (catalog.get('organization') or {}).get('tracks', [])}

    def canonical(identity):
        seen = set()
        while identity in aliases:
            if identity in seen:
                raise ValueError('Destination track alias cycle')
            seen.add(identity)
            identity = aliases[identity]
        if identity not in known:
            raise ValueError('Destination track alias has no logical track')
        return identity

    index = {}
    logical_hashes = {}
    for entry in entries.values():
        track = entry['track']
        identity = canonical(track['id'])
        if identity in logical_hashes and logical_hashes[identity] != entry['sha256']:
            raise ValueError('Logical destination track has competing content hashes')
        logical_hashes[identity] = entry['sha256']
        key = tuple(normalized(track.get(field)) for field in ('title', 'artist', 'album'))
        if all(key):
            index.setdefault(key, {})[(identity, entry['sha256'])] = {
                'track': {**track, 'id': identity}, 'sha256': entry['sha256']}

    result = {}
    persistent = [track.get('Persistent ID') for track in library['Tracks'].values()]
    existing = [value for value in persistent if value]
    if len(existing) != len(set(existing)):
        raise ValueError('Duplicate source track persistent identity')
    for source_id, track in library['Tracks'].items():
        key = tuple(normalized(track.get(field)) for field in ('Name', 'Artist', 'Album'))
        candidates = []
        if all(key) and isinstance(track.get('Total Time'), (int, float)):
            for entry in index.get(key, {}).values():
                target = entry['track']
                duration = target.get('duration')
                if not isinstance(duration, (int, float)) or abs(duration * 1000 - track['Total Time']) > 2000:
                    continue
                if any(track.get(source) is not None and
                       (target.get(dest) or (1 if dest == 'discNumber' else None)) != track[source]
                       for source, dest in (('Track Number', 'track'), ('Disc Number', 'discNumber'))):
                    continue
                candidates.append({'track_id': target['id'], 'sha256': entry['sha256']})
        candidates.sort(key=lambda c: c['track_id'])
        result[str(source_id)] = {
            'source_track_id': str(source_id), 'persistent_id': track.get('Persistent ID'),
            'title': track.get('Name', ''), 'artist': track.get('Artist', ''),
            'album': track.get('Album', ''), 'duration_ms': track.get('Total Time'),
            'track_number': track.get('Track Number'), 'disc_number': track.get('Disc Number'),
            'status': 'candidate' if len(candidates) == 1 else 'ambiguous' if candidates else 'unmatched',
            'candidates': candidates,
        }
    return result


def write_csv(path, fields, rows):
    with path.open('x', encoding='utf-8-sig', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def read_csv(path, identity, decisions):
    result = {}
    with path.open(encoding='utf-8-sig', newline='') as handle:
        for row in csv.DictReader(handle):
            key = row[identity]
            if key in result or row['decision'] not in decisions:
                raise ValueError('Duplicate review row or unsupported decision')
            result[key] = row
    return result


def create_review(library_path, catalog_path, output):
    library, catalog, provenance = source_inputs(library_path, catalog_path)
    records = playlist_records(library)
    tracks = candidate_tracks(library, catalog)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    playlists = []
    for record in records.values():
        if record['kind'] == 'system':
            continue
        counts = {status: sum(tracks.get(i, {}).get('status', 'unmatched') == status for i in record['items'])
                  for status in ('candidate', 'ambiguous', 'unmatched')}
        playlists.append({'decision': '', 'playlist_id': record['id'], 'kind': record['kind'],
                          'path': record['path'], 'occurrences': len(record['items']), **counts})
    write_csv(output / 'playlists.csv',
              ['decision', 'playlist_id', 'kind', 'path', 'occurrences', 'candidate', 'ambiguous', 'unmatched'],
              playlists)
    referenced = {i for record in records.values() for i in record['items']}
    rows = []
    for identity, track in tracks.items():
        if identity not in referenced:
            continue
        candidates = track['candidates']
        rows.append({'decision': '', 'source_track_id': identity,
                     'title': track['title'], 'artist': track['artist'], 'album': track['album'],
                     'status': track['status'], 'destination_track_id': candidates[0]['track_id'] if len(candidates) == 1 else '',
                     'candidate_track_ids': json.dumps([c['track_id'] for c in candidates]),
                     'duration_ms': track['duration_ms'], 'track_number': track['track_number'],
                     'disc_number': track['disc_number']})
    write_csv(output / 'tracks.csv', ['decision', 'source_track_id', 'title', 'artist', 'album',
              'status', 'destination_track_id', 'candidate_track_ids', 'duration_ms', 'track_number', 'disc_number'], rows)
    with (output / 'source.json').open('x', encoding='utf-8') as handle:
        json.dump(provenance, handle, indent=2)
    return {'playlists': len(playlists), 'referenced_tracks': len(rows),
            **{status: sum(row['status'] == status for row in rows)
               for status in ('candidate', 'ambiguous', 'unmatched')}}


def prepare(library_path, catalog_path, review, output):
    library, catalog, provenance = source_inputs(library_path, catalog_path)
    review = Path(review)
    if json.loads((review / 'source.json').read_text()) != provenance:
        raise ValueError('Source or server catalog changed; create a new review')
    records = playlist_records(library)
    tracks = candidate_tracks(library, catalog)
    selections = read_csv(review / 'playlists.csv', 'playlist_id', {'', 'yes', 'no'})
    if set(selections) != {i for i, record in records.items() if record['kind'] != 'system'}:
        raise ValueError('Playlist review identities changed')
    selected = {i for i, row in selections.items() if row['decision'] == 'yes'}
    folders = {i for i in selected if records[i]['kind'] == 'folder'}
    selected.update(i for i, record in records.items() if folders.intersection(record['ancestors'])
                    and i in selections and selections[i]['decision'] != 'no')
    selected = {i for i in selected if records[i]['kind'] in ('manual', 'snapshot')}
    if not selected:
        raise ValueError('Select at least one playlist with decision=yes')
    mapping_rows = read_csv(review / 'tracks.csv', 'source_track_id', {'', 'accept', 'skip'})
    expected = {i for r in records.values() for i in r['items'] if i in tracks}
    if set(mapping_rows) != expected:
        raise ValueError('Track review identities changed')
    mappings = {}
    for identity, row in mapping_rows.items():
        if row['decision'] != 'accept':
            continue
        match = next((c for c in tracks[identity]['candidates'] if c['track_id'] == row['destination_track_id']), None)
        if match is None:
            raise ValueError(f'Accepted track {identity} is not a listed candidate')
        mappings[identity] = match
    needed = set(selected)
    for identity in selected:
        needed.update(records[identity]['ancestors'])
    playlists = []
    for identity, record in records.items():
        if identity not in needed:
            continue
        items = []
        for position, source_id in enumerate(record['items']):
            # Stable occurrence identities apply to this exact source fingerprint.
            occurrence = digest(json.dumps([provenance['source_sha256'], identity, position]).encode())
            items.append({'id': occurrence, 'position': position,
                          'source_track_id': source_id, 'source': tracks.get(source_id),
                          'destination': mappings.get(source_id),
                          'match_evidence': 'user-reviewed-metadata' if source_id in mappings else 'unresolved'})
        playlists.append({'source_playlist_id': identity, 'name': record['name'],
                          'kind': record['kind'], 'parent': record['parent'],
                          'definition': record['definition'], 'items': items})
    bundle = {'version': 1, 'state': 'prepared-not-imported', **provenance, 'playlists': playlists}
    with Path(output).open('x', encoding='utf-8') as handle:
        json.dump(bundle, handle, ensure_ascii=False, indent=2)
        handle.write('\n')
    items = [item for record in playlists for item in record['items']]
    return {'selected_playlists': len(selected), 'occurrences': len(items),
            'resolved': sum(item['destination'] is not None for item in items),
            'unresolved': sum(item['destination'] is None for item in items),
            'state': bundle['state']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('review', 'prepare'):
        command = commands.add_parser(name)
        command.add_argument('--library', type=Path, required=True)
        command.add_argument('--catalog', type=Path, required=True, help='JSON exported from the destination server')
        command.add_argument('--output', type=Path, required=True)
        if name == 'prepare':
            command.add_argument('--review', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = (create_review(args.library, args.catalog, args.output) if args.command == 'review' else
                  prepare(args.library, args.catalog, args.review, args.output))
    except (ValueError, KeyError, OSError, plistlib.InvalidFileException) as error:
        parser.error(str(error))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
