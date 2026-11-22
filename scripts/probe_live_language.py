#!/usr/bin/env python3
"""Opt-in, serial installed-model comparison. Raw logs stay in --output.

The JSON manifest supplies cases with name, files, optional env, references,
languages/tail_languages, empty_first and min_partials. It is local test data,
not a source of executable commands. No model or recording is downloaded.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import unicodedata
import wave


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def normalized(text):
    return ''.join(c for c in unicodedata.normalize('NFC', text).lower()
                   if unicodedata.category(c)[0] in 'LN')


def character_errors(reference, hypothesis):
    reference, hypothesis = normalized(reference), normalized(hypothesis)
    previous = list(range(len(hypothesis) + 1))
    for i, expected in enumerate(reference, 1):
        current = [i]
        for j, actual in enumerate(hypothesis, 1):
            current.append(min(current[-1] + 1, previous[j] + 1,
                               previous[j - 1] + (expected != actual)))
        previous = current
    return {'errors': previous[-1], 'characters': len(reference)}


def parse_outputs(stdout, events):
    invalid = []
    for name, raw in [('stdout', stdout), ('events', events)]:
        try:
            raw.decode('utf-8', errors='strict')
        except UnicodeDecodeError:
            invalid.append(name)
    # Retain baseline failures as measurable results, not a decoder crash.
    rows = [json.loads(line) for line in events.decode('utf-8', 'replace').splitlines() if line]
    return invalid, rows


def evaluate(case, result):
    failures = []
    if result['returncode'] != 0:
        failures.append('engine exit')
    if result['invalid_utf8']:
        failures.append('invalid UTF-8')
    if not result['segments']:
        failures.append('missing committed segments')
    languages = [s['lang'] for s in result['segments']]
    if 'languages' in case and languages != case['languages']:
        failures.append('language sequence')
    tail = case.get('tail_languages')
    if tail and languages[-len(tail):] != tail:
        failures.append('language recovery')
    if case.get('empty_first') and (not result['segments'] or result['segments'][0]['text_present']):
        failures.append('failed provisional text published')
    if result['partials'] < case.get('min_partials', 0):
        failures.append('missing partial output')
    if case.get('require_text') and not any(s['text_present'] for s in result['segments']):
        failures.append('missing transcript')
    if case.get('require_all_text') and not all(s['text_present'] for s in result['segments']):
        failures.append('missing segment text')
    return failures


def run_case(args, engine, case, output):
    output.mkdir(parents=True, exist_ok=False)
    files = [Path(p).resolve(strict=True) for p in case['files']]
    for file in files:
        if '\n' in str(file) or '\r' in str(file):
            raise ValueError('A stream path cannot contain line breaks')
    event_path = output / 'events.jsonl'
    env = os.environ.copy()
    for key in ['WHISPER_LANG_ID', 'LANG_CANDIDATES', 'PROMPT', 'APP_FILE',
                'DIAR_K', 'VOICEPRINTS', 'VOICEPRINT_PROFILES', 'TRANSLATE']:
        env.pop(key, None)
    env.update(STREAM='1', STREAM_WAV_ROOTS=':'.join(sorted({str(p.parent) for p in files})),
               AUDIO_CTX='auto', PARTIALS='1', CONF='1', DIAR='1', OSD='1',
               DIAR_MAXK='8', VAD_PROB='0.50', ENC_F16_CACHE='1', EVENTS_FILE=str(event_path))
    overrides = case.get('env', {})
    if set(overrides) - {'WHISPER_LANG_ID', 'LANG_CANDIDATES'}:
        raise ValueError('Only language settings may be overridden by a case')
    env.update(overrides)
    offset, lines = 0.0, []
    for file in files:
        with wave.open(str(file)) as audio:
            if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
                raise ValueError(f'Expected mono PCM16 at 16 kHz: {file}')
            seconds = audio.getnframes() / audio.getframerate()
        lines.append(f'{offset:.6f} {file}\n')
        offset += seconds
    started = time.monotonic()
    process = subprocess.run([str(engine), str(args.model), '/dev/null', str(args.assets / 'WHISPER_BPE.bin')],
                             cwd=args.assets, env=env, input=(''.join(lines) + 'FLUSH\n').encode(),
                             capture_output=True, timeout=args.timeout)
    elapsed = time.monotonic() - started
    (output / 'stdout.log').write_bytes(process.stdout)
    (output / 'stderr.log').write_bytes(process.stderr)
    invalid, rows = parse_outputs(process.stdout, event_path.read_bytes() if event_path.exists() else b'')
    segments = [r for r in rows if r.get('t') == 'seg']
    actual = ' '.join(s.get('text', '') for s in segments)
    result = {'returncode': process.returncode, 'seconds': elapsed, 'audio_seconds': offset,
              'invalid_utf8': invalid, 'partials': sum(r.get('t') == 'partial' for r in rows),
              'segments': [{k: s.get(k) for k in ['lang', 'dropped', 'avg_logprob']} |
                           {'text_present': bool(s.get('text', '').strip())} for s in segments]}
    if case.get('references'):
        result['cer'] = character_errors(' '.join(case['references']), actual)
    result['failures'] = evaluate(case, result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['engine', 'baseline-engine', 'model', 'assets', 'manifest', 'output']:
        parser.add_argument('--' + name, type=Path, required=name != 'baseline-engine')
    parser.add_argument('--timeout', type=float, default=180)
    args = parser.parse_args()
    for name in ['engine', 'baseline_engine', 'model', 'assets', 'manifest']:
        if getattr(args, name) is not None:
            setattr(args, name, getattr(args, name).resolve(strict=True))
    args.output = args.output.resolve()
    cases = json.loads(args.manifest.read_text())['cases']
    names = [case['name'] for case in cases]
    if len(set(names)) != len(names) or not all(re.fullmatch(r'[a-zA-Z0-9_-]+', n) for n in names):
        raise ValueError('Case names must be unique safe path components')
    args.output.mkdir(parents=True, exist_ok=False)
    report = {'schema_version': 1, 'model_sha256': digest(args.model),
              'engine_sha256': digest(args.engine), 'manifest_sha256': digest(args.manifest),
              'baseline_sha256': digest(args.baseline_engine) if args.baseline_engine else None, 'cases': []}
    for case in cases:
        row = {'name': case['name'], 'inputs': [digest(f) for f in case['files']]}
        for label, engine in [('baseline', args.baseline_engine), ('candidate', args.engine)]:
            if engine:
                row[label] = run_case(args, engine, case, args.output / case['name'] / label)
        if 'baseline' in row and (row['baseline']['returncode'] != 0 or not row['baseline']['segments']):
            row['candidate']['failures'].append('baseline execution incomplete')
        if 'baseline' in row and 'cer' in row['candidate']:
            if row['candidate']['cer']['errors'] > row['baseline']['cer']['errors'] + case.get('allowed_extra_errors', 0):
                row['candidate']['failures'].append('recognition regressed against baseline')
        report['cases'].append(row)
        (args.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({'case': case['name'], 'candidate': row['candidate']}, ensure_ascii=False), flush=True)
    raise SystemExit(1 if any(c['candidate']['failures'] for c in report['cases']) else 0)


if __name__ == '__main__':
    main()
