#!/usr/bin/env python3
"""Compare two live-diarization runs on user-visible correction quality.

Usage:
  python3 bench/live_ux_gate.py RUN_BASELINE RUN_CANDIDATE --require-win
  python3 bench/live_ux_gate.py RUN_WITH_CAUSAL_OSD --causal-self --require-win

Each argument may be a results.jsonl file or its containing run directory.
The verdict is deliberately asymmetric: a candidate must preserve first-seen
DER and wrong-label exposure, while a material improvement on any UX axis can
establish a WIN.  Final/FLUSH DER remains a separate recorded-path gate.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path


MEAN_REGRESSION_LIMITS = {
    "der": 0.05,
    "wrong_visible_ratio_pct": 0.05,
    # Compare the absolute unresolved-window count. A candidate that removes
    # some first-seen errors while leaving the same unresolved tail is a win;
    # the percentage alone rises because its denominator got smaller.
    "unresolved_wrong_windows": 0.00,
    "label_churn_per_min": 0.25,
    "first_label_latency_p90_sec": 0.10,
    "time_to_correct_p90_sec": 5.00,
    "causal_osd_der": 0.05,
}

CASE_REGRESSION_LIMITS = {
    "der": 0.10,
    "wrong_visible_ratio_pct": 0.25,
    "unresolved_wrong_windows": 0.00,
    "speaker_overcount_peak": 0.00,
    "causal_osd_der": 0.10,
}

WIN_LIMITS = {
    "der": -0.10,
    "wrong_visible_ratio_pct": -0.25,
    "unresolved_wrong_windows": -0.25,
    "label_churn_per_min": -0.25,
    "time_to_correct_p90_sec": -2.00,
    "causal_osd_der": -0.10,
    "causal_overlap_unresolved_sec": -0.25,
}


def results_path(path: Path) -> Path:
    return path / "results.jsonl" if path.is_dir() else path


def load(path: Path) -> dict[str, dict]:
    actual = results_path(path)
    records: dict[str, dict] = {}
    with actual.open() as f:
        for line in f:
            record = json.loads(line)
            if record.get("mode") == "live_stream" and "ux_windows" in record:
                records[record["id"]] = record
    if not records:
        raise ValueError(f"no live_stream UX records in {actual}")
    return records


def mean(records: dict[str, dict], ids: list[str], metric: str) -> float | None:
    values = [records[case_id].get(metric) for case_id in ids]
    present = [float(value) for value in values if value is not None]
    return statistics.mean(present) if present else None


def fmt(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.2f}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path, nargs="?")
    parser.add_argument(
        "--causal-self",
        action="store_true",
        help=(
            "within one run, compare primary DER with causal OSD DER and "
            "reference overlap duration with unresolved overlap duration"
        ),
    )
    parser.add_argument(
        "--require-win",
        action="store_true",
        help="exit 2 for NOISE; useful when deciding whether to keep an experiment",
    )
    args = parser.parse_args()

    if args.causal_self:
        if args.candidate is not None:
            parser.error("--causal-self accepts one run, not a candidate run")
        candidate = load(args.baseline)
        baseline = {}
        for case_id, record in candidate.items():
            if record.get("causal_osd_der") is None:
                raise ValueError(f"{case_id} has no causal_osd_der")
            before = dict(record)
            before["causal_osd_der"] = record.get("der")
            before["causal_overlap_unresolved_sec"] = record.get(
                "causal_overlap_reference_sec"
            )
            baseline[case_id] = before
    else:
        if args.candidate is None:
            parser.error("candidate run is required unless --causal-self is used")
        baseline = load(args.baseline)
        candidate = load(args.candidate)
    ids = sorted(set(baseline) & set(candidate))
    if not ids:
        raise ValueError("baseline and candidate have no matching live cases")
    missing = sorted(set(baseline) ^ set(candidate))

    regressions: list[str] = []
    wins: list[str] = []
    rows: list[tuple[str, float | None, float | None, float | None]] = []
    metrics = list(
        dict.fromkeys(
            [
                *MEAN_REGRESSION_LIMITS,
                *WIN_LIMITS,
                "unresolved_initial_wrong_pct",
            ]
        )
    )
    for metric in metrics:
        before = mean(baseline, ids, metric)
        after = mean(candidate, ids, metric)
        delta = None if before is None or after is None else after - before
        rows.append((metric, before, after, delta))
        if delta is None:
            continue
        if delta > MEAN_REGRESSION_LIMITS.get(metric, float("inf")):
            regressions.append(
                f"mean {metric} {before:.2f}->{after:.2f} ({delta:+.2f})"
            )
        if delta <= WIN_LIMITS.get(metric, -float("inf")):
            wins.append(f"mean {metric} {before:.2f}->{after:.2f} ({delta:+.2f})")

    for case_id in ids:
        for metric, limit in CASE_REGRESSION_LIMITS.items():
            before = baseline[case_id].get(metric)
            after = candidate[case_id].get(metric)
            if before is None or after is None:
                continue
            delta = float(after) - float(before)
            if delta > limit:
                regressions.append(
                    f"{case_id} {metric} {float(before):.2f}->{float(after):.2f} ({delta:+.2f})"
                )

    # A lower total peak overcount is a material panel-UX win even when the DER
    # mapping makes the percentage metrics nearly flat.
    before_overcount = sum(max(0, baseline[i]["speaker_overcount_peak"]) for i in ids)
    after_overcount = sum(max(0, candidate[i]["speaker_overcount_peak"]) for i in ids)
    if after_overcount < before_overcount:
        wins.append(f"total peak overcount {before_overcount}->{after_overcount}")

    if missing:
        regressions.append("case-set mismatch: " + ", ".join(missing))

    verdict = "REGR" if regressions else ("WIN" if wins else "NOISE")
    print(f"matched cases: {len(ids)} ({', '.join(ids)})")
    print("\n| metric | baseline | candidate | delta |")
    print("|---|---:|---:|---:|")
    for metric, before, after, delta in rows:
        delta_text = "n/a" if delta is None else f"{delta:+.2f}"
        print(f"| {metric} | {fmt(before)} | {fmt(after)} | {delta_text} |")
    print(f"\nverdict: {verdict}")
    for item in regressions:
        print(f"  REGR: {item}")
    for item in wins:
        print(f"  WIN:  {item}")

    if verdict == "REGR":
        return 1
    if verdict == "NOISE" and args.require_win:
        return 2
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
