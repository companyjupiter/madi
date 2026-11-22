import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import wave

import probe_live_language as probe


class LiveLanguageProbeTests(unittest.TestCase):
    def test_invalid_partial_bytes_cannot_pass_as_replacement_text(self):
        invalid, rows = probe.parse_outputs(b'valid stdout', b'{"t":"partial","text":"\xed\x95"}\n')
        self.assertEqual(invalid, ['events'])
        self.assertEqual(rows[0]['t'], 'partial')

    def test_missing_events_and_disabled_partials_are_not_success(self):
        result = {'returncode': 0, 'invalid_utf8': [], 'segments': [], 'partials': 0}
        failures = probe.evaluate({'min_partials': 1, 'require_text': True}, result)
        self.assertIn('missing committed segments', failures)
        self.assertIn('missing partial output', failures)
        self.assertIn('missing transcript', failures)

    def test_error_count_normalizes_unicode_but_penalizes_dropped_speech(self):
        self.assertEqual(probe.character_errors('한글 문장.', '한글문장'), {'errors': 0, 'characters': 4})
        self.assertEqual(probe.character_errors('한글 문장', ''), {'errors': 4, 'characters': 4})

    @unittest.skipUnless(os.name == 'posix', 'The installed Metal process probe is macOS-only')
    def test_relative_output_is_collected_from_engine_asset_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assets = root / 'asset cwd'
            assets.mkdir()
            (assets / 'WHISPER_BPE.bin').write_bytes(b'fixture')
            (root / 'model').write_bytes(b'fixture')
            audio = root / '한국어 음성.wav'
            with wave.open(str(audio), 'wb') as handle:
                handle.setparams((1, 2, 16000, 16, 'NONE', 'not compressed'))
                handle.writeframes(b'\0\0' * 16)
            engine = root / 'fake-engine'
            engine.write_text('#!/usr/bin/env python3\nimport json,os,pathlib,sys\n'
                              'sys.stdin.read()\n'
                              'rows=[{"t":"partial","text":"한"},'
                              '{"t":"seg","lang":50264,"text":"한글","dropped":False}]\n'
                              'pathlib.Path(os.environ["EVENTS_FILE"]).write_text('
                              '"".join(json.dumps(r)+"\\n" for r in rows))\n')
            engine.chmod(0o700)
            manifest = root / 'manifest.json'
            manifest.write_text(json.dumps({'cases': [{'name': 'fixture', 'files': [str(audio)],
                                'languages': [50264], 'min_partials': 1, 'require_text': True}]}))
            command = [sys.executable, str(Path(probe.__file__).resolve()), '--engine', str(engine),
                       '--model', str(root / 'model'), '--assets', str(assets),
                       '--manifest', str(manifest), '--output', 'relative-output']
            result = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads((root / 'relative-output/summary.json').read_text())
            self.assertEqual(report['cases'][0]['candidate']['failures'], [])
            self.assertFalse((assets / 'relative-output').exists())


if __name__ == '__main__':
    unittest.main()
