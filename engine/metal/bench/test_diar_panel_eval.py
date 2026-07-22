#!/usr/bin/env python3

import tempfile
import unittest
from pathlib import Path

from diar_panel_eval import parse_md_eval, write_rttm_with_overlaps


class DiarPanelEvalTests(unittest.TestCase):
    def test_md_eval_component_units_are_explicit(self) -> None:
        parsed = parse_md_eval(
            """
            SCORED SPEAKER TIME =100.00 secs
            MISSED SPEAKER TIME =2.00 secs
            FALARM SPEAKER TIME =1.00 secs
            SPEAKER ERROR TIME =3.00 secs
            OVERALL SPEAKER DIARIZATION ERROR = 6.00 percent
            """
        )

        self.assertEqual(parsed["miss"], 2.0)
        self.assertEqual(parsed["miss_pct"], 2.0)
        self.assertEqual(parsed["fa_pct"], 1.0)
        self.assertEqual(parsed["conf_pct"], 3.0)
        self.assertEqual(parsed["der"], 6.0)

    def test_overlap_union_does_not_duplicate_primary_speaker(self) -> None:
        labels = {0.0: (0, 1.5)}
        overlaps = [(0.5, 0, 1.0), (0.5, 1, 0.5)]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "union.rttm"
            overlap_rows = write_rttm_with_overlaps(
                labels, overlaps, path, "sample"
            )
            rows = path.read_text().splitlines()

        self.assertEqual(overlap_rows, 2)
        self.assertEqual(len(rows), 2)
        self.assertIn(" 0.000 1.500 ", rows[0])
        self.assertIn(" spk0 ", rows[0])
        self.assertIn(" 0.500 0.500 ", rows[1])
        self.assertIn(" spk1 ", rows[1])


if __name__ == "__main__":
    unittest.main()
