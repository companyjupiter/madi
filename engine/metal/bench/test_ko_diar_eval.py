#!/usr/bin/env python3

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from ko_diar_eval import (
    KitCase,
    sha256,
    validate_kit,
    word_support_intervals,
    write_word_support_rttm,
)


class KoreanDiarEvalTests(unittest.TestCase):
    def test_kit_hash_mismatch_is_fatal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "audio").mkdir()
            (root / "groundtruth").mkdir()
            audio = root / "audio/sample.wav"
            rttm = root / "groundtruth/sample.rttm"
            words = root / "groundtruth/sample.words.json"
            audio.write_bytes(b"audio")
            rttm.write_bytes(b"rttm")
            words.write_bytes(b"words")
            spec = KitCase(
                "sample",
                1,
                sha256(audio),
                sha256(rttm),
                "0" * 64,
            )
            with patch("ko_diar_eval.KIT_CASES", (spec,)):
                with self.assertRaisesRegex(ValueError, "words SHA256 mismatch"):
                    validate_kit(root)

    def test_word_support_padding_and_merge_are_deterministic(self) -> None:
        payload = {
            "name": "sample",
            "words": [
                {"start": 0.2, "end": 0.5, "spk": "A"},
                {"start": 0.8, "end": 1.0, "spk": "A"},
                {"start": 1.8, "end": 2.0, "spk": "A"},
                {"start": 0.4, "end": 0.7, "spk": "B"},
            ],
        }
        with tempfile.TemporaryDirectory() as directory:
            words = Path(directory) / "sample.words.json"
            words.write_text(json.dumps(payload))
            case_id, rows = word_support_intervals(words)

        self.assertEqual(case_id, "sample")
        self.assertEqual(
            rows,
            [
                (0.1, 1.1, "A"),
                (0.30000000000000004, 0.7999999999999999, "B"),
                (1.7, 2.1, "A"),
            ],
        )

    def test_word_support_rttm_reports_covered_seconds(self) -> None:
        payload = {
            "name": "sample",
            "words": [{"start": 0.0, "end": 0.5, "spk": "A"}],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            words = root / "sample.words.json"
            rttm = root / "sample.rttm"
            words.write_text(json.dumps(payload))
            seconds = write_word_support_rttm(words, rttm)
            row = rttm.read_text()

        self.assertAlmostEqual(seconds, 0.6)
        self.assertIn("SPEAKER sample 1 0.000 0.600", row)


if __name__ == "__main__":
    unittest.main()
