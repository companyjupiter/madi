#!/usr/bin/env python3
"""Reproducible Korean diarization gate for the local madi_diar_kit.

The kit's RTTM rows cover utterance blocks, including pauses between words.
This runner scores that canonical reference and a derived word-support
reference. The second score is diagnostic: it prevents an apparent DER win
from merely turning internal silence into speech.

Example:
  python3 bench/ko_diar_eval.py \
    --kit-root ~/Documents/madi_diar_kit \
    --out-dir bench/runs/ko_diar_baseline
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import time
from dataclasses import dataclass
from pathlib import Path

from diar_panel_eval import (
    Case,
    ROOT,
    eval_case,
    eval_live_case,
    require,
    score,
    to_wav16,
)


@dataclass(frozen=True)
class KitCase:
    case_id: str
    speakers: int
    audio_sha256: str
    rttm_sha256: str
    words_sha256: str


KIT_CASES = (
    KitCase(
        "ko_meeting_full",
        3,
        "74101f010c80ecd9fa7ca948d51e381e4c321a1b638da154ed9eeb3197988c7c",
        "69ecdfa7c64cdc4249230f0d2d7c9c16aea17eec2a484835c719ab28628c03f6",
        "09327869aed90f569f48181097bbcf5dc237ca2406b6471904758013bff19898",
    ),
    KitCase(
        "ko_spk_probe",
        3,
        "42b77d10070f6aa1d9afe3b5de6973fbfcbcbab2d21e4cddf82cdf7a09d3c006",
        "d4ed140dced0d821981bef574f5782801df7ab5fafa49ece3e988e84e2c76132",
        "675d8a1def6769ba1e37538d8f3f6a4291906cf331b67b2572533584f05b33ba",
    ),
)

WORD_PAD_SEC = 0.10
MERGE_PADDED_GAP_SEC = 0.25


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def kit_paths(root: Path, spec: KitCase) -> tuple[Path, Path, Path]:
    return (
        root / "audio" / f"{spec.case_id}.wav",
        root / "groundtruth" / f"{spec.case_id}.rttm",
        root / "groundtruth" / f"{spec.case_id}.words.json",
    )


def validate_kit(root: Path) -> dict[str, dict[str, str]]:
    provenance: dict[str, dict[str, str]] = {}
    for spec in KIT_CASES:
        audio, rttm, words = kit_paths(root, spec)
        expected = {
            "audio": (audio, spec.audio_sha256),
            "rttm": (rttm, spec.rttm_sha256),
            "words": (words, spec.words_sha256),
        }
        actual: dict[str, str] = {}
        for label, (path, expected_hash) in expected.items():
            require(path, f"{spec.case_id} {label}")
            actual_hash = sha256(path)
            if actual_hash != expected_hash:
                raise ValueError(
                    f"{spec.case_id} {label} SHA256 mismatch: "
                    f"expected {expected_hash}, got {actual_hash}"
                )
            actual[label] = actual_hash
        provenance[spec.case_id] = actual
    return provenance


def word_support_intervals(words_path: Path) -> tuple[str, list[tuple[float, float, str]]]:
    payload = json.loads(words_path.read_text())
    case_id = str(payload["name"])
    by_speaker: dict[str, list[tuple[float, float]]] = {}
    for word in payload["words"]:
        start = max(0.0, float(word["start"]) - WORD_PAD_SEC)
        end = float(word["end"]) + WORD_PAD_SEC
        by_speaker.setdefault(str(word["spk"]), []).append((start, end))

    rows: list[tuple[float, float, str]] = []
    for speaker, spans in by_speaker.items():
        start, end = sorted(spans)[0]
        for next_start, next_end in sorted(spans)[1:]:
            if next_start <= end + MERGE_PADDED_GAP_SEC:
                end = max(end, next_end)
            else:
                rows.append((start, end, speaker))
                start, end = next_start, next_end
        rows.append((start, end, speaker))
    return case_id, sorted(rows)


def write_word_support_rttm(words_path: Path, out_path: Path) -> float:
    case_id, rows = word_support_intervals(words_path)
    with out_path.open("w") as handle:
        for start, end, speaker in rows:
            handle.write(
                f"SPEAKER {case_id} 1 {start:.3f} {end - start:.3f} "
                f"<NA> <NA> {speaker} <NA> <NA>\n"
            )
    return sum(end - start for start, end, _ in rows)


def add_word_support_score(record: dict, ref: Path) -> dict:
    metrics = score(ref, Path(record["rttm"]))
    for key, value in metrics.items():
        record[f"word_support_{key}"] = value
    return record


def run_profile(
    *,
    profile: str,
    case: Case,
    wav: Path,
    out_dir: Path,
    word_ref: Path,
    live: bool,
    env: dict[str, str] | None = None,
    no_recluster: bool = False,
) -> list[dict]:
    profile_dir = out_dir / profile
    profile_dir.mkdir(exist_ok=True)
    if live:
        records = eval_live_case(
            case,
            wav,
            profile_dir,
            env or {},
            10.0,
            3.0,
            no_recluster,
        )
    else:
        mode = "forced" if profile == "file_forced" else "auto"
        records = [eval_case(case, mode, wav, profile_dir, env or {})]
    for record in records:
        record["profile"] = profile
        add_word_support_score(record, word_ref)
    return records


def fmt(value: object) -> str:
    if value is None:
        return ""
    return f"{value:.2f}" if isinstance(value, float) else str(value)


def write_summary(records: list[dict], out_path: Path, support_seconds: dict[str, float]) -> None:
    lines = [
        "# Korean diarization evaluation",
        "",
        "Canonical DER uses the kit's utterance-block RTTM. Word-support DER uses "
        f"word spans padded by {WORD_PAD_SEC:.2f}s and merged when the padded gap is "
        f"at most {MERGE_PADDED_GAP_SEC:.2f}s.",
        "",
        "| id | profile | mode | speakers | auto-K | block DER % | word DER % | miss s | FA s | conf s | wrong-visible % | overcount |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for record in records:
        lines.append(
            f"| {record['id']} | {record['profile']} | {record['mode']} | "
            f"{fmt(record.get('engine_speakers'))} | {fmt(record.get('auto_k'))} | "
            f"{fmt(record.get('der'))} | {fmt(record.get('word_support_der'))} | "
            f"{fmt(record.get('miss'))} | {fmt(record.get('fa'))} | {fmt(record.get('conf'))} | "
            f"{fmt(record.get('wrong_visible_ratio_pct'))} | {fmt(record.get('speaker_overcount_peak'))} |"
        )
    lines.extend(["", "## Word-support reference duration", ""])
    for case_id, seconds in support_seconds.items():
        lines.append(f"- `{case_id}`: {seconds:.3f}s")
    out_path.write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--kit-root",
        type=Path,
        default=Path(os.environ.get("MADI_DIAR_KIT", "~/Documents/madi_diar_kit")).expanduser(),
    )
    parser.add_argument("--out-dir", type=Path)
    parser.add_argument(
        "--profile",
        action="append",
        choices=(
            "file_auto",
            "file_forced",
            "live_auto",
            "live_auto_norecluster",
            "live_fixed",
            "live_fixed_norecluster",
        ),
        help="repeat to select profiles; default runs all",
    )
    args = parser.parse_args()

    require(ROOT / "out/transcribe", "engine binary")
    provenance = validate_kit(args.kit_root)
    out_dir = args.out_dir or ROOT / "bench/runs" / (
        "ko_diar_" + time.strftime("%Y%m%d_%H%M%S")
    )
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "provenance.json").write_text(
        json.dumps(provenance, indent=2, ensure_ascii=False) + "\n"
    )

    selected = set(args.profile or (
        "file_auto",
        "file_forced",
        "live_auto",
        "live_auto_norecluster",
        "live_fixed",
        "live_fixed_norecluster",
    ))
    records: list[dict] = []
    support_seconds: dict[str, float] = {}
    scratch = out_dir / "scratch"
    scratch.mkdir(exist_ok=True)
    for spec in KIT_CASES:
        audio, block_ref, words = kit_paths(args.kit_root, spec)
        word_ref = scratch / f"{spec.case_id}.word_support.rttm"
        support_seconds[spec.case_id] = write_word_support_rttm(words, word_ref)
        wav = scratch / f"{spec.case_id}.wav"
        to_wav16(audio, wav)
        case = Case(spec.case_id, audio, block_ref, spec.speakers)
        profiles = (
            ("file_auto", False, {}, False),
            ("file_forced", False, {}, False),
            ("live_auto", True, {}, False),
            ("live_auto_norecluster", True, {}, True),
            ("live_fixed", True, {"DIAR_K": str(spec.speakers)}, False),
            ("live_fixed_norecluster", True, {"DIAR_K": str(spec.speakers)}, True),
        )
        for profile, live, env, no_recluster in profiles:
            if profile not in selected:
                continue
            for record in run_profile(
                profile=profile,
                case=case,
                wav=wav,
                out_dir=out_dir,
                word_ref=word_ref,
                live=live,
                env=env,
                no_recluster=no_recluster,
            ):
                records.append(record)
                print(json.dumps(record, ensure_ascii=False))

    with (out_dir / "results.jsonl").open("w") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    write_summary(records, out_dir / "summary.md", support_seconds)
    print(f"summary: {out_dir / 'summary.md'}")


if __name__ == "__main__":
    main()
