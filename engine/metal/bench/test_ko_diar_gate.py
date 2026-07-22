#!/usr/bin/env python3

import unittest

from ko_diar_gate import compare


def record(**values: float) -> dict:
    return {
        "id": "ko_spk_probe",
        "profile": "live_fixed",
        "mode": "live_stream",
        **values,
    }


class KoreanDiarGateTests(unittest.TestCase):
    def test_rejects_block_der_win_that_worsens_word_support(self) -> None:
        record_key = ("ko_spk_probe", "live_fixed", "live_stream")
        baseline = {
            record_key: record(der=18.0, word_support_der=10.0, miss=5.0, fa=0.1)
        }
        candidate = {
            record_key: record(der=15.0, word_support_der=10.2, miss=5.0, fa=0.1)
        }

        verdict, regressions, wins, _ = compare(baseline, candidate)

        self.assertEqual(verdict, "REGR")
        self.assertTrue(any("word_support_der" in item for item in regressions))
        self.assertTrue(any("der" in item for item in wins))

    def test_accepts_consistent_der_win(self) -> None:
        record_key = ("ko_spk_probe", "live_fixed", "live_stream")
        baseline = {
            record_key: record(
                der=18.0,
                word_support_der=10.0,
                miss=5.0,
                fa=0.1,
                speaker_overcount_peak=1,
            )
        }
        candidate = {
            record_key: record(
                der=11.0,
                word_support_der=7.0,
                miss=5.0,
                fa=0.1,
                speaker_overcount_peak=0,
            )
        }

        verdict, regressions, wins, _ = compare(baseline, candidate)

        self.assertEqual(verdict, "WIN")
        self.assertEqual(regressions, [])
        self.assertGreaterEqual(len(wins), 3)


if __name__ == "__main__":
    unittest.main()
