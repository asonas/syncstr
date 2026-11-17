"""Read-only iTunes XML playlist and local-file observations; never imports music."""

import argparse
import base64
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
from urllib.parse import unquote, urlsplit


def local_path(location):
    uri = urlsplit(location)
    if uri.scheme != 'file' or uri.query or uri.fragment:
        raise ValueError('Not a plain file URI')
    # Do not contact remote shares during a local-only audit.
    if uri.netloc and uri.netloc.lower() != 'localhost':
        raise ValueError('Remote file URI requires separate review')
    path = unquote(uri.path, errors='strict')
    if re.match(r'^/[A-Za-z]:/', path):
        if os.name != 'nt':
            raise ValueError('Windows file URI requires Windows')
        path = path[1:]
    if '\x00' in path or path.startswith(('//', '\\\\')) or not Path(path).is_absolute():
        raise ValueError('Not an absolute local path')
    return Path(path)


def inspect_track(track):
    result = {'evidence': {key: track[key] for key in
              ('Kind', 'Track Type', 'Purchased', 'Matched', 'Protected', 'Apple Music')
              if key in track}, 'eligibility': 'unresolved', 'playability': 'not_tested'}
    if track.get('Apple Music') is True or 'apple music' in str(track.get('Kind', '')).lower():
        result['eligibility'] = 'subscription_excluded'
    if 'Location' not in track:
        result['file_status'] = 'no_location'
        return result
    try:
        path = local_path(track['Location'])
    except (ValueError, UnicodeError) as error:
        result.update(file_status='location_not_checked', detail=str(error))
        return result
    result['path'] = str(path)
    result['protection'] = ('flagged' if track.get('Protected') is True or
                            path.suffix.lower() == '.m4p' else 'not_verified')
    try:
        stat = path.stat()
        result['size'] = stat.st_size
        # Avoid hydrating offline/cloud placeholders just to test readability.
        if getattr(stat, 'st_file_attributes', 0) & (0x1000 | 0x40000 | 0x400000):
            result['file_status'] = 'placeholder_not_read'
        elif not path.is_file():
            result['file_status'] = 'not_file'
        else:
            with path.open('rb') as audio:
                result['file_status'] = 'readable' if audio.read(1) else 'empty'
    except FileNotFoundError:
        result['file_status'] = 'missing'
    except OSError as error:
        result.update(file_status='unreadable', error_code=error.errno)
    return result


def analyze(library):
    tracks = library['Tracks']
    observations = {key: inspect_track(track) for key, track in tracks.items()}
    playlists = []
    for source in library['Playlists']:
        positions = defaultdict(list)
        items = []
        for position, item in enumerate(source.get('Playlist Items', []), 1):
            track_id = str(item.get('Track ID'))
            positions[track_id].append(position)
            track = tracks.get(track_id)
            items.append({'position': position, 'track_id': track_id,
                          'persistent_id': track.get('Persistent ID') if track else None,
                          'name': track.get('Name') if track else None,
                          'resolved_in_xml': track is not None})
        smart = any(key in source for key in ('Smart Info', 'Smart Criteria'))
        system = source.get('Master') is True or 'Distinguished Kind' in source
        kind = ('folder' if source.get('Folder') is True else 'system' if system
                else 'smart' if smart else 'ordinary')
        playlists.append({
            'name': source.get('Name'), 'persistent_id': source.get('Playlist Persistent ID'),
            'parent_persistent_id': source.get('Parent Persistent ID'), 'kind': kind,
            'has_smart_definition': smart, 'count': len(items), 'items': items,
            'duplicate_positions': {key: value for key, value in positions.items() if len(value) > 1},
            'smart_data_base64': {key: base64.b64encode(source[key]).decode('ascii')
                                  for key in ('Smart Info', 'Smart Criteria') if key in source},
            'app_comparison': 'not_verified', 'smart_semantics': 'not_decoded' if smart else 'not_applicable',
        })
    ids = Counter(p['persistent_id'] for p in playlists)
    nonfolders = [p for p in playlists if p['kind'] != 'folder']
    summary = {
        'tracks': len(tracks), 'playlists': len(playlists),
        'playlist_kinds': dict(Counter(p['kind'] for p in playlists)),
        'nonfolder_smart': sum(p['has_smart_definition'] for p in nonfolders),
        'nonfolder_without_smart': sum(not p['has_smart_definition'] for p in nonfolders),
        'broken_track_references': sum(not i['resolved_in_xml'] for p in playlists for i in p['items']),
        'duplicate_playlists': sum(bool(p['duplicate_positions']) for p in nonfolders),
        'extra_duplicate_occurrences': sum(len(v)-1 for p in nonfolders for v in p['duplicate_positions'].values()),
        'missing_parent_references': sum(bool(p['parent_persistent_id']) and p['parent_persistent_id'] not in ids for p in playlists),
        'ambiguous_playlist_ids': sum(count > 1 for count in ids.values()),
        'file_status': dict(Counter(t['file_status'] for t in observations.values())),
        'protection': dict(Counter(t.get('protection', 'not_checked') for t in observations.values())),
        'eligibility': dict(Counter(t['eligibility'] for t in observations.values())),
    }
    return {'summary': summary, 'playlists': playlists, 'tracks': observations}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New private JSON file outside source directories')
    args = parser.parse_args()
    source = args.library.resolve()
    output = args.output.resolve()
    raw = source.read_bytes()
    library = plistlib.loads(raw)
    protected = {source.parent}
    for track in library['Tracks'].values():
        try:
            protected.add(local_path(track['Location']).resolve().parent)
        except (KeyError, ValueError, UnicodeError):
            pass
    if any(output == path or path in output.parents for path in protected):
        parser.error('Output must be outside source library and audio directories')
    if output.exists():
        parser.error('Output already exists; choose a new filename')
    report = analyze(library)
    report['source'] = {'sha256': hashlib.sha256(raw).hexdigest(),
                        'date': str(library.get('Date')), 'application_version': library.get('Application Version'),
                        'library_persistent_id': library.get('Library Persistent ID'),
                        'unchanged_at_end': source.read_bytes() == raw}
    report['observed_at'] = datetime.now(timezone.utc).isoformat()
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('x', encoding='utf-8') as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
        handle.write('\n')
    print(json.dumps({'source': {k: v for k, v in report['source'].items() if k != 'library_persistent_id'},
                      'summary': report['summary']}, indent=2))


if __name__ == '__main__':
    main()
