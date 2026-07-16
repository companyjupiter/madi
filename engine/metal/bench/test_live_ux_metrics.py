#!/usr/bin/env python3

import tempfile
import unittest
from pathlib import Path

from live_ux_metrics import analyze_live_ux, parse_label_events


class LiveUxMetricsTests(unittest.TestCase):
    def test_time_to_correct_excludes_flush_repairs(self) -> None:
        stdout = """\
SPK 0.000 0 1.500 1.0
<<SEG_END>>
SPK 10.000 0 1.500 0.1
SPK 12.000 1 1.500 0.8
<<SEG_END>>
SPK 20.000 0 1.500 0.8
SPKFIX 10.000 1 1.500 0.7
<<SEG_END>>
SPKFIX 0.000 1 1.500 0.9
<<FLUSH_END>>
"""
        with tempfile.TemporaryDirectory() as tmp:
            ref = Path(tmp) / "panel.rttm"
            ref.write_text(
                "SPEAKER panel 1 0.000 1.500 <NA> <NA> A <NA> <NA>\n"
                "SPEAKER panel 1 10.000 1.500 <NA> <NA> B <NA> <NA>\n"
                "SPEAKER panel 1 12.000 1.500 <NA> <NA> B <NA> <NA>\n"
                "SPEAKER panel 1 20.000 1.500 <NA> <NA> A <NA> <NA>\n"
            )
            metrics = analyze_live_ux(stdout, [10.0, 20.0, 30.0], ref)

        self.assertEqual(metrics["ux_ref_windows"], 4)
        self.assertEqual(metrics["initially_wrong_windows"], 1)
        self.assertEqual(metrics["corrected_windows"], 1)
        self.assertEqual(metrics["unresolved_wrong_windows"], 0)
        self.assertAlmostEqual(metrics["immediate_correct_pct"], 75.0)
        self.assertAlmostEqual(metrics["final_mid_correct_pct"], 100.0)
        self.assertAlmostEqual(metrics["time_to_correct_p50_sec"], 10.0)
        self.assertAlmostEqual(metrics["time_to_correct_p90_sec"], 10.0)
        self.assertAlmostEqual(metrics["wrong_visible_ratio_pct"], 25.0)
        self.assertEqual(metrics["label_changes"], 1)
        self.assertAlmostEqual(metrics["label_churn_per_min"], 2.0)
        self.assertEqual(metrics["visible_speakers_peak"], 2)
        self.assertEqual(metrics["visible_speakers_final_mid"], 2)
        self.assertEqual(metrics["first_margin_ambiguous_windows"], 1)
        self.assertAlmostEqual(metrics["first_margin_ambiguous_wrong_pct"], 100.0)
        self.assertEqual(metrics["first_margin_confident_windows"], 2)
        self.assertAlmostEqual(metrics["first_margin_confident_wrong_pct"], 0.0)
        self.assertEqual(metrics["first_margin_sentinel_windows"], 1)
        self.assertAlmostEqual(metrics["first_margin_sentinel_wrong_pct"], 0.0)

    def test_segment_frontier_and_flush_classification(self) -> None:
        stdout = """\
SPK 0.0 0 1.5 1.0
<<SEG_END>>
SPKFIX 0.0 1 1.5 0.5
<<SEG_END>>
SPKFIX 0.0 2 1.5 0.5
"""
        events = parse_label_events(stdout, [10.0, 20.0])
        self.assertEqual([event.visible_at for event in events], [10.0, 20.0, 20.0])
        self.assertEqual([event.during_flush for event in events], [False, False, True])
        self.assertEqual([event.margin for event in events], [1.0, 0.5, 0.5])

    def test_negative_margin_is_preserved_as_ambiguous(self) -> None:
        events = parse_label_events("SPK 1.5 2 1.5 -0.03\n", [10.0])
        self.assertEqual(len(events), 1)
        self.assertAlmostEqual(events[0].margin, -0.03)


if __name__ == "__main__":
    unittest.main()
