#!/usr/bin/env python3

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("live_ux_gate.py")


def record(*, der: float, initially_wrong: int, unresolved: int) -> dict:
    return {
        "id": "panel",
        "mode": "live_stream",
        "ux_windows": 20,
        "der": der,
        "wrong_visible_ratio_pct": 10.0,
        "initially_wrong_windows": initially_wrong,
        "unresolved_wrong_windows": unresolved,
        "unresolved_initial_wrong_pct": 100.0 * unresolved / initially_wrong,
        "label_churn_per_min": 8.0,
        "first_label_latency_p90_sec": 10.0,
        "time_to_correct_p90_sec": 20.0,
        "speaker_overcount_peak": 0,
    }


class LiveUxGateTests(unittest.TestCase):
    def run_gate(self, baseline: dict, candidate: dict) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            before = root / "before.jsonl"
            after = root / "after.jsonl"
            before.write_text(json.dumps(baseline) + "\n")
            after.write_text(json.dumps(candidate) + "\n")
            return subprocess.run(
                [sys.executable, str(SCRIPT), str(before), str(after), "--require-win"],
                text=True,
                capture_output=True,
            )

    def run_causal_self(self, candidate: dict) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "candidate.jsonl"
            path.write_text(json.dumps(candidate) + "\n")
            return subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(path),
                    "--causal-self",
                    "--require-win",
                ],
                text=True,
                capture_output=True,
            )

    def test_smaller_error_denominator_does_not_fake_unresolved_regression(self) -> None:
        result = self.run_gate(
            record(der=20.0, initially_wrong=10, unresolved=5),
            record(der=18.0, initially_wrong=5, unresolved=5),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("verdict: WIN", result.stdout)

    def test_additional_unresolved_window_is_a_regression(self) -> None:
        result = self.run_gate(
            record(der=20.0, initially_wrong=10, unresolved=5),
            record(der=18.0, initially_wrong=8, unresolved=6),
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("unresolved_wrong_windows", result.stdout)

    def test_causal_self_compares_osd_with_primary_in_one_run(self) -> None:
        candidate = record(der=10.0, initially_wrong=5, unresolved=3)
        candidate.update(
            causal_osd_der=8.0,
            causal_overlap_reference_sec=5.0,
            causal_overlap_unresolved_sec=3.0,
        )
        result = self.run_causal_self(candidate)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("causal_osd_der | 10.00 | 8.00 | -2.00", result.stdout)

    def test_causal_self_blocks_per_case_tail(self) -> None:
        candidate = record(der=10.0, initially_wrong=5, unresolved=3)
        candidate.update(
            causal_osd_der=10.2,
            causal_overlap_reference_sec=5.0,
            causal_overlap_unresolved_sec=5.0,
        )
        result = self.run_causal_self(candidate)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("panel causal_osd_der", result.stdout)


if __name__ == "__main__":
    unittest.main()
