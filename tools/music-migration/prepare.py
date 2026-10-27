"""Prepare reviewed local tracks for the headless Entry/Organization contract."""

import base64
import json
from pathlib import Path
import shutil
import subprocess
import uuid

from migration import classify
from transfer import digest, read_json, write_json


def identifier(value):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, 'syncstr-migration:' + value))


def prepare(inventory_path, selection_path, output, ffmpeg, ffprobe):
    inventory = read_json(inventory_path)
    selection = read_json(selection_path)
    if inventory.get('format_version') != 1 or selection.get('format_version') != 1:
        raise ValueError('Unsupported inventory or selection format')
    source = inventory['source']
    if digest(Path(source['xml_path'])) != source['xml_sha256']:
        raise ValueError('Source XML changed; create a fresh inventory and review it')
    if selection['library_persistent_id'] != source['library_persistent_id']:
        raise ValueError('Selection belongs to another source library')
    records = {r['source_id']: r for r in inventory['tracks']}
    picks = selection['tracks']
    if not picks or len({r['source_id'] for r in picks}) != len(picks):
        raise ValueError('Selection must contain unique source records')
    output = output.resolve()
    protected = [Path(source['xml_path']).resolve().parent]
    protected.extend(Path(r['availability']['path']).resolve().parent
                     for r in inventory['tracks'] if 'path' in r['availability'])
    if any(output == p or p in output.parents for p in protected):
        raise ValueError('Output must be outside source directories')
    if output.exists():
        raise ValueError('Output must be a new directory')
    chosen = []
    hashes = set()
    for pick in picks:
        record = records[pick['source_id']]
        decision, reason = classify(record['source_evidence'], record['availability'])
        observation = pick.get('cloud_observation', {})
        resolved = (reason == 'ownership_unresolved'
                    and observation.get('status') in ('uploaded', 'matched', 'purchased')
                    and observation.get('method') and observation.get('observed_at'))
        if (decision != 'candidate' and not resolved) or record.get('duplicate_location'):
            raise ValueError(f"Unconfirmed selection: {record['source_id']} ({reason})")
        if record['availability']['status'] != 'readable':
            raise ValueError('Only locally readable audio is supported; downloads are separate')
        path = Path(record['availability']['path'])
        if path.suffix.lower() not in ('.mp3', '.m4a', '.aac', '.flac', '.wav', '.aiff', '.aif', '.alac'):
            raise ValueError('Unsupported source audio type')
        hash_value = digest(path)
        if hash_value != pick['audio_sha256'] or hash_value in hashes:
            raise ValueError('Changed or duplicate audio requires review')
        hashes.add(hash_value)
        chosen.append((pick, record, path))
    output.mkdir(parents=True)
    result = []
    for pick, record, path in chosen:
        sid = record['source_id']
        tid = identifier(sid)
        item = output / tid
        item.mkdir()
        suffix = path.suffix.lower().lstrip('.')
        audio = item / ('audio.' + suffix)
        shutil.copyfile(path, audio)
        if digest(audio) != pick['audio_sha256'] or digest(path) != pick['audio_sha256']:
            raise ValueError('Source audio changed during preparation')
        probe = json.loads(subprocess.check_output([
            ffprobe, '-v', 'error', '-show_format', '-show_streams', '-of', 'json', str(audio)]))
        # Malformed cover declarations must not prevent verification of the audio stream.
        decoding = subprocess.run([ffmpeg, '-nostdin', '-v', 'error', '-xerror',
                                   '-i', str(audio), '-map', '0:a:0', '-f', 'null', '-'],
                                  capture_output=True)
        if decoding.returncode or decoding.stderr:
            hint = pick.get('artwork_decoder_hint')
            if hint != 'mjpeg':
                raise ValueError(f'Audio verification requires review: {sid}')
            subprocess.run([ffmpeg, '-nostdin', '-v', 'error', '-xerror', '-c:v', hint,
                            '-i', str(audio), '-map', '0:a:0', '-f', 'null', '-'],
                           check=True, capture_output=True)
        meta = record['source_metadata']
        if not meta.get('Name'):
            raise ValueError('Title requires review')
        album = meta.get('Album') or ''
        folder = identifier(str(path.resolve().parent))
        credit = meta.get('Album Artist') or meta.get('Artist') or tid
        aid = identifier(folder + ':' + album + ':' + credit) if album else identifier('album-unset:' + sid)
        imported = {'title': meta.get('Album'), 'artist': meta.get('Artist'),
                    'albumArtist': meta.get('Album Artist'),
                    'compilationValues': [str(meta['Compilation']).lower()] if 'Compilation' in meta else []}
        track = {'id': tid, 'title': meta['Name'], 'artist': meta.get('Artist'),
                 'album': album, 'albumId': aid, 'track': meta.get('Track Number'),
                 'discNumber': meta.get('Disc Number'), 'suffix': suffix, 'size': audio.stat().st_size,
                 'duration': float(probe['format']['duration'])}
        org = {'albums': [{'id': aid, 'title': album, 'releases': []}],
               'tracks': [{'id': tid, 'sha256': pick['audio_sha256'], 'imported': imported,
                           'importedAlbumID': aid, 'title': meta['Name'],
                           'importContext': {'sourceID': identifier(source['library_persistent_id']), 'folder': folder},
                           'discNumber': meta.get('Disc Number'), 'trackNumber': meta.get('Track Number')}],
               'aliases': {}, 'choices': [], 'preferred': {}}
        entry = {'track': track, 'sha256': pick['audio_sha256'], 'importedAlbum': imported}
        asset = None
        artwork_status = 'missing'
        original_image_hash = None
        artwork_error = None
        if pick.get('artwork'):
            image_source = Path(pick['artwork']['path'])
            try:
                original_image_hash = digest(image_source)
                if original_image_hash != pick['artwork']['sha256']:
                    raise ValueError('Artwork changed since review')
                image = item / 'cover.jpg'
                subprocess.run([ffmpeg, '-nostdin', '-v', 'error', '-i', str(image_source),
                                '-vf', "scale=w='min(400,iw)':h='min(400,ih)':force_original_aspect_ratio=decrease",
                                '-frames:v', '1', '-q:v', '2', str(image)], check=True, capture_output=True)
                image_probe = json.loads(subprocess.check_output([
                    ffprobe, '-v', 'error', '-show_entries', 'stream=codec_name,width,height',
                    '-of', 'json', str(image)]))['streams'][0]
                if (image.stat().st_size > 512 * 1024 or image_probe['codec_name'] != 'mjpeg'
                        or max(image_probe['width'], image_probe['height']) > 400):
                    raise ValueError('Normalized artwork exceeds the server contract')
                encoded = base64.b64encode(image.read_bytes()).decode('ascii')
                asset = digest(image)
                entry['artwork'] = encoded
                track['coverArt'] = tid
                org['artwork'] = {'assets': {asset: encoded}, 'candidates': [{
                    'id': identifier(tid + ':' + asset), 'track': tid, 'source': 'music',
                    'context': sid, 'asset': asset, 'parents': []}], 'preferred': {}}
                artwork_status = 'prepared'
            except (OSError, subprocess.CalledProcessError) as error:
                artwork_status = 'unavailable'
                artwork_error = str(error)
        write_json(item / 'entry.json', entry)
        write_json(item / 'organization.json', org)
        write_json(item / 'source-evidence.json', {
            'source_id': sid, 'library_metadata': meta, 'embedded_metadata': probe,
            'ownership': record['source_evidence'], 'cloud_observation': pick.get('cloud_observation'),
            'original_artwork_sha256': original_image_hash, 'normalized_artwork_sha256': asset,
            'artwork_status': artwork_status, 'artwork_error': artwork_error})
        files = ['entry.json', 'organization.json', 'source-evidence.json', 'audio.' + suffix]
        result.append({'id': tid, 'source_id': sid, 'sha256': pick['audio_sha256'],
                       'size': track['size'], 'suffix': suffix, 'asset': asset,
                       'artwork_status': artwork_status,
                       'files': {name: digest(item / name) for name in files}})
    if digest(Path(source['xml_path'])) != source['xml_sha256']:
        raise ValueError('Source XML changed during preparation; review a new inventory')
    write_json(output / 'manifest.json', {'format_version': 1, 'tracks': result,
               'source_xml_sha256': source['xml_sha256']})
    print(f'Prepared {len(result)} reviewed tracks; missing artwork: {sum(r["asset"] is None for r in result)}')
