#!/usr/bin/env python3
"""Optional fresh-ASR spot checks for ambiguous or stale transcript evidence."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import posixpath
import shutil
import subprocess
from pathlib import Path
from statistics import median
from xml.etree import ElementTree as ET
from zipfile import ZipFile

AUDIT_PATH = Path(__file__).with_name('audit_readalouds.py')
SPEC = importlib.util.spec_from_file_location('readaloud_audit', AUDIT_PATH)
assert SPEC and SPEC.loader
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)

COPIES = Path('.')
OUTPUT = Path('.')
WHISPER = Path(shutil.which('whisper-cli') or 'whisper-cli')
MODEL = Path('.')
FFMPEG = Path(shutil.which('ffmpeg') or 'ffmpeg')


def state_for(book: str) -> dict:
    for path in (OUTPUT / 'state').glob('*.json'):
        data = json.loads(path.read_text(encoding='utf-8'))
        if data.get('book') == book:
            return data
    raise FileNotFoundError(f'no audit state for {book}')


def parse_documents(archive: ZipFile, items: list[dict]) -> dict[str, dict[str, str]]:
    documents = {}
    for item in items:
        member = item['member']
        try:
            root = ET.fromstring(archive.read(member))
            documents[member] = {
                element.get('id'): ''.join(element.itertext()).strip()
                for element in root.iter()
                if element.get('id')
            }
        except ET.ParseError:
            parser = audit.LenientIDTextParser()
            parser.feed(archive.read(member).decode('utf-8', 'replace'))
            documents[member] = parser.values()
    return documents


def epub_clips(epub: Path) -> tuple[ZipFile, list[dict]]:
    archive = ZipFile(epub)
    container = ET.fromstring(archive.read('META-INF/container.xml'))
    rootfile = container.find('.//c:rootfile', audit.NS_CONTAINER)
    if rootfile is None:
        raise ValueError('no rootfile')
    opf_path = rootfile.get('full-path')
    assert opf_path
    opf = ET.fromstring(archive.read(opf_path))
    manifest = {}
    for element in opf.iter():
        if audit.local_name(element.tag) != 'item' or not element.get('id') or not element.get('href'):
            continue
        member, _ = audit.resolve_member(opf_path, element.get('href'))
        manifest[element.get('id')] = {
            'id': element.get('id'),
            'member': member,
            'media_type': element.get('media-type'),
            'media_overlay': element.get('media-overlay'),
        }
    spine = [
        manifest[element.get('idref')]
        for element in opf.iter()
        if audit.local_name(element.tag) == 'itemref' and element.get('idref') in manifest
    ]
    contents = [
        item for item in manifest.values()
        if item['media_type'] in {'application/xhtml+xml', 'text/html'}
        or item['member'].lower().endswith(('.xhtml', '.html', '.htm'))
    ]
    documents = parse_documents(archive, contents)
    smil_ids = []
    for item in spine:
        if item.get('media_overlay') and item['media_overlay'] in manifest:
            smil_ids.append(item['media_overlay'])
    for item in manifest.values():
        if item['media_type'] == 'application/smil+xml' and item['id'] not in smil_ids:
            smil_ids.append(item['id'])
    clips = []
    for smil_id in smil_ids:
        smil_member = manifest[smil_id]['member']
        root = ET.fromstring(archive.read(smil_member))
        for par in (element for element in root.iter() if audit.local_name(element.tag) == 'par'):
            text_element = next((element for element in par if audit.local_name(element.tag) == 'text'), None)
            audio_element = next((element for element in par if audit.local_name(element.tag) == 'audio'), None)
            if text_element is None or audio_element is None:
                continue
            text_member, fragment = audit.resolve_member(smil_member, text_element.get('src', ''))
            audio_member, _ = audit.resolve_member(smil_member, audio_element.get('src', ''))
            if not fragment:
                continue
            clips.append({
                'chapter': text_member,
                'fragment': fragment,
                'text': documents.get(text_member, {}).get(fragment, ''),
                'audio_member': audio_member,
                'audio_name': posixpath.basename(audio_member),
                'begin': audit.parse_clock(audio_element.get('clipBegin')),
                'end': audit.parse_clock(audio_element.get('clipEnd')),
            })
    return archive, clips


def choose_indices(clips: list[dict], state: dict, count: int, distributed: bool) -> list[int]:
    if not clips:
        return []
    if count == 1:
        return [len(clips) // 2]
    if distributed:
        return sorted(set(round(i * (len(clips) - 1) / (count - 1)) for i in range(count)))
    by_key = {(clip['chapter'], clip['fragment']): index for index, clip in enumerate(clips)}
    evidence_indices = [
        by_key[(item['chapter'], item['fragment'])]
        for item in state.get('evidence', [])
        if (item['chapter'], item['fragment']) in by_key
    ]
    evidence_indices = sorted(set(evidence_indices))
    if len(evidence_indices) >= count:
        return [evidence_indices[round(i * (len(evidence_indices) - 1) / (count - 1))] for i in range(count)]
    return sorted(set(round(i * (len(clips) - 1) / (count - 1)) for i in range(count)))


def transcript_text(data: dict) -> str:
    transcription = data.get('transcription')
    if isinstance(transcription, list):
        return ' '.join(str(item.get('text', '')) for item in transcription)
    if isinstance(transcription, str):
        return transcription
    segments = data.get('segments')
    if isinstance(segments, list):
        return ' '.join(str(item.get('text', '')) for item in segments)
    if isinstance(data.get('text'), str):
        return data['text']
    result = data.get('result')
    if isinstance(result, dict) and isinstance(result.get('text'), str):
        return result['text']
    return ''


def detected_language(data: dict) -> str | None:
    for value in (
        data.get('language'),
        (data.get('result') or {}).get('language') if isinstance(data.get('result'), dict) else None,
        (data.get('params') or {}).get('language') if isinstance(data.get('params'), dict) else None,
    ):
        if value:
            return str(value)
    return None


def run_book(book: str, force: bool, count: int, distributed: bool) -> dict:
    state = state_for(book)
    epub = next((COPIES / book / 'aligned').glob('*.epub'))
    archive, clips = epub_clips(epub)
    indices = choose_indices(clips, state, count, distributed)
    book_dir = OUTPUT / 'samples' / audit.hashlib.sha256(book.encode()).hexdigest()[:12]
    tracks_dir = book_dir / 'tracks'
    book_dir.mkdir(parents=True, exist_ok=True)
    tracks_dir.mkdir(parents=True, exist_ok=True)
    results = []
    try:
        prepared = []
        for sample_number, index in enumerate(indices, 1):
            clip = clips[index]
            center = (clip['begin'] + clip['end']) / 2
            start = max(0.0, center - 22.5)
            end = start + 45.0
            reference_clips = [
                candidate for candidate in clips
                if candidate['audio_member'] == clip['audio_member']
                and candidate['end'] >= start and candidate['begin'] <= end
            ]
            reference = ' '.join(candidate['text'] for candidate in reference_clips)
            track_path = tracks_dir / clip['audio_name']
            if not track_path.exists():
                with archive.open(clip['audio_member']) as source, track_path.open('wb') as destination:
                    shutil.copyfileobj(source, destination, 4 * 1024 * 1024)
            stem = book_dir / f'sample-{sample_number:02d}'
            wav = stem.with_suffix('.wav')
            asr_json = stem.with_suffix('.json')
            if force or not wav.exists():
                subprocess.run([
                    str(FFMPEG), '-hide_banner', '-loglevel', 'error', '-y',
                    '-ss', f'{start:.3f}', '-i', str(track_path), '-t', '45',
                    '-ar', '16000', '-ac', '1', str(wav),
                ], check=True, timeout=120, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            prepared.append((sample_number, clip, start, reference, wav, asr_json))

        missing = [item for item in prepared if force or not item[5].exists()]
        if missing:
            subprocess.run([
                str(WHISPER), '-m', str(MODEL), '-l', 'auto', '-oj', '-np', '-nt',
                *[str(item[4]) for item in missing],
            ], check=True, timeout=max(900, 300 * len(missing)), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _, _, _, _, wav, asr_json in missing:
                generated = Path(str(wav) + '.json')
                if not generated.exists():
                    raise FileNotFoundError(f'Whisper did not create {generated}')
                os.replace(generated, asr_json)

        for sample_number, clip, start, reference, wav, asr_json in prepared:
            data = json.loads(asr_json.read_text(encoding='utf-8'))
            spoken = transcript_text(data)
            ref_tokens = audit.tokens(reference)
            spoken_tokens = audit.tokens(spoken)
            precision, recall, f1, matched = audit.score_tokens(ref_tokens, spoken_tokens)
            result = {
                'sample': sample_number,
                'chapter': clip['chapter'],
                'fragment': clip['fragment'],
                'audio': clip['audio_name'],
                'start': start,
                'duration': 45.0,
                'reference_tokens': len(ref_tokens),
                'spoken_tokens': len(spoken_tokens),
                'matched_tokens': matched,
                'precision': precision,
                'recall': recall,
                'similarity': f1,
                'detected_language': detected_language(data),
                'reference_excerpt': audit.excerpt(reference, 30),
                'transcript_excerpt': audit.excerpt(spoken, 30),
                'wav': str(wav),
                'json': str(asr_json),
            }
            results.append(result)
            print(f'  sample {sample_number}/{len(indices)} {clip["audio_name"]} {start:.1f}s -> {f1:.1%}', flush=True)
    finally:
        archive.close()
    similarities = [item['similarity'] for item in results]
    summary = {
        'book': book,
        'sample_count': len(results),
        'median_similarity': median(similarities) if similarities else None,
        'weighted_similarity': (
            sum(item['similarity'] * item['reference_tokens'] for item in results)
            / sum(item['reference_tokens'] for item in results)
            if sum(item['reference_tokens'] for item in results) else None
        ),
        'samples_at_least_070': sum(value >= 0.70 for value in similarities),
        'samples_at_least_085': sum(value >= 0.85 for value in similarities),
        'languages': sorted(set(item['detected_language'] for item in results if item['detected_language'])),
        'samples': results,
    }
    audit.atomic_json(book_dir / 'summary.json', summary)
    return summary


def main() -> int:
    global COPIES, OUTPUT, WHISPER, MODEL, FFMPEG
    parser = argparse.ArgumentParser(
        description='Extract embedded samples, transcribe them with whisper.cpp, and compare them to SMIL-referenced XHTML.'
    )
    parser.add_argument('--readaloud-root', type=Path, required=True)
    parser.add_argument('--audit-output', type=Path, required=True)
    parser.add_argument('--whisper-cli', type=Path, default=WHISPER)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--ffmpeg', type=Path, default=FFMPEG)
    parser.add_argument('--book', action='append', help='exact asset-folder name; repeatable')
    parser.add_argument('--samples', type=int, default=3)
    parser.add_argument(
        '--distributed', action='store_true',
        help='sample evenly across the entire overlay instead of prioritizing prior worst evidence',
    )
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    if args.samples < 1:
        parser.error('--samples must be at least 1')
    COPIES = args.readaloud_root
    OUTPUT = args.audit_output
    WHISPER = args.whisper_cli
    MODEL = args.model
    FFMPEG = args.ffmpeg
    if args.book:
        books = args.book
    else:
        queue_path = OUTPUT / 'needs_fresh_asr.json'
        if not queue_path.exists():
            parser.error('provide --book or run audit_readalouds.py to create needs_fresh_asr.json')
        books = [item['book'] for item in json.loads(queue_path.read_text(encoding='utf-8'))]
    results = []
    for index, book in enumerate(books, 1):
        print(f'[{index}/{len(books)}] fresh ASR {book}', flush=True)
        results.append(run_book(book, args.force, args.samples, args.distributed))
    audit.atomic_json(OUTPUT / 'fresh_asr_summary.json', results)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
