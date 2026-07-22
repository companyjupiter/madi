#!/usr/bin/env python3
"""Compare two ko_diar_eval runs and reject disguised diarization wins."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


CASE_LIMITS = {
    "der": 0.10,
    "word_support_der": 0.10,
    "miss": 0.05,
    "fa": 0.05,
    "wrong_visible_ratio_pct": 0.25,
    "unresolved_wrong_windows": 0.00,
    "speaker_overcount_peak": 0.00,
}

WIN_LIMITS = {
    "der": -0.10,
    "word_support_der": -0.10,
    "wrong_visible_ratio_pct": -0.25,
    "unresolved_wrong_windows": -0.25,
    "label_churn_per_min": -0.25,
    "speaker_overcount_peak": -1.00,
}


def results_path(path: Path) -> Path:
    return path / "results.jsonl" if path.is_dir() else path


def key(record: dict) -> tuple[str, str, str]:
    return str(record["id"]), str(record["profile"]), str(record["mode"])


def load(path: Path) -> dict[tuple[str, str, str], dict]:
    records: dict[tuple[str, str, str], dict] = {}
    with results_path(path).open() as handle:
        for line in handle:
            record = json.loads(line)
            record_key = key(record)
            if record_key in records:
                raise ValueError(f"duplicate record: {record_key}")
            records[record_key] = record
    if not records:
        raise ValueError(f"no records in {results_path(path)}")
    return records


def compare(
    baseline: dict[tuple[str, str, str], dict],
    candidate: dict[tuple[str, str, str], dict],
) -> tuple[str, list[str], list[str], list[tuple[str, str, float, float, float]]]:
    matched = sorted(set(baseline) & set(candidate))
    if not matched:
        raise ValueError("baseline and candidate have no matching records")

    regressions: list[str] = []
    wins: list[str] = []
    rows: list[tuple[str, str, float, float, float]] = []
    metrics = list(dict.fromkeys((*CASE_LIMITS, *WIN_LIMITS)))
    for record_key in matched:
        label = "/".join(record_key)
        before_record = baseline[record_key]
        after_record = candidate[record_key]
        for metric in metrics:
            before = before_record.get(metric)
            after = after_record.get(metric)
            if before is None or after is None:
                continue
            before_float = float(before)
            after_float = float(after)
            delta = after_float - before_float
            rows.append((label, metric, before_float, after_float, delta))
            if delta > CASE_LIMITS.get(metric, float("inf")):
                regressions.append(
                    f"{label} {metric} {before_float:.2f}->{after_float:.2f} ({delta:+.2f})"
                )
            if delta <= WIN_LIMITS.get(metric, -float("inf")):
                wins.append(
                    f"{label} {metric} {before_float:.2f}->{after_float:.2f} ({delta:+.2f})"
                )

    verdict = "REGR" if regressions else ("WIN" if wins else "NOISE")
    return verdict, regressions, wins, rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--require-win", action="store_true")
    args = parser.parse_args()

    verdict, regressions, wins, rows = compare(load(args.baseline), load(args.candidate))
    print("| record | metric | baseline | candidate | delta |")
    print("|---|---|---:|---:|---:|")
    for label, metric, before, after, delta in rows:
        print(f"| {label} | {metric} | {before:.2f} | {after:.2f} | {delta:+.2f} |")
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
