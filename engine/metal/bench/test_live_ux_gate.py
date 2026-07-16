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


if __name__ == "__main__":
    unittest.main()
