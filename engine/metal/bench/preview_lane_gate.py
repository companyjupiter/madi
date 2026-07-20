#!/usr/bin/env python3
"""Real-model regression gate for the single-process STREAM PREVIEW lane.

Runs a committed SEG once as a baseline, then PREVIEW→the same SEG in another
resident process. Transcript/language/diar state must stay identical; only
sub-threshold floating score noise is tolerated after a preceding GPU job.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--engine", type=Path, default=ROOT / "out/transcribe")
    p.add_argument("--model", type=Path, default=ROOT / "assets/model.safetensors")
    p.add_argument("--bpe", type=Path, default=ROOT / "assets/WHISPER_BPE.bin")
    p.add_argument("--assets-dir", type=Path, default=ROOT / "assets")
    p.add_argument("--wav", type=Path, default=ROOT / "assets/jfk.wav")
    return p.parse_args()


def run_engine(a: argparse.Namespace, events: Path, with_preview: bool) -> tuple[str, float]:
    wav = str(a.wav.resolve())
    commands = f"0.000 {wav}\nFLUSH\n"
    if with_preview:
        commands = f"PREVIEW {wav}\n" + commands
    env = {
        **os.environ,
        "STREAM": "1",
        "DIAR": "1",
        "OSD": "1",
        "WHISPER_LANG_ID": "50259",
        "STREAM_WAV_ROOTS": str(a.wav.resolve().parent),
        "EVENTS_FILE": str(events),
    }
    started = time.monotonic()
    proc = subprocess.run(
        [a.engine.resolve(), a.model.resolve(), "/dev/null", a.bpe.resolve()],
        input=commands,
        text=True,
        capture_output=True,
        cwd=a.assets_dir,
        env=env,
        check=True,
    )
    return proc.stdout, time.monotonic() - started


def normalized_events(path: Path) -> list[dict]:
    ignored = {"tok_s", "enc_ms", "dec_ms"}
    events = []
    for line in path.read_text().splitlines():
        item = json.loads(line)
        events.append({k: v for k, v in item.items() if k not in ignored})
    return events


def assert_state_equivalent(base: list[dict], candidate: list[dict]) -> dict[str, float]:
    assert len(base) == len(candidate), "PREVIEW changed committed event count"
    max_delta = {"conf": 0.0, "avg_logprob": 0.0}
    # Metal reductions are not guaranteed bit-deterministic after another job
    # has occupied the same buffers. Treat sub-0.005 score drift as numeric noise;
    # text, timestamps, speaker ids, barriers and every other field stay exact.
    tolerances = {"conf": 0.005, "avg_logprob": 0.005}
    for i, (left, right) in enumerate(zip(base, candidate, strict=True)):
        left = dict(left)
        right = dict(right)
        for key, tolerance in tolerances.items():
            if key not in left and key not in right:
                continue
            assert key in left and key in right, f"event {i}: {key} field missing"
            delta = abs(float(left.pop(key)) - float(right.pop(key)))
            max_delta[key] = max(max_delta[key], delta)
            assert delta <= tolerance, f"event {i}: {key} drift {delta:.6f} > {tolerance}"
        assert left == right, f"event {i}: PREVIEW mutated committed state: {left} != {right}"
    return max_delta


def main() -> None:
    a = parse_args()
    for path in (a.engine, a.model, a.bpe, a.assets_dir, a.wav):
        if not path.exists():
            raise SystemExit(f"missing gate input: {path}")

    with tempfile.TemporaryDirectory(prefix="madi-preview-gate-") as td:
        tmp = Path(td)
        base_out, base_s = run_engine(a, tmp / "base.jsonl", False)
        preview_out, preview_s = run_engine(a, tmp / "preview.jsonl", True)
        base_events = normalized_events(tmp / "base.jsonl")
        preview_events = normalized_events(tmp / "preview.jsonl")

    max_delta = assert_state_equivalent(base_events, preview_events)
    assert preview_out.count("<<PREVIEW_BEGIN>>") == 1
    assert preview_out.count("<<PREVIEW_END>>") == 1
    assert preview_out.count("<<SEG_END>>") == 1
    assert preview_out.count("<<FLUSH_END>>") == 1
    begin = preview_out.index("<<PREVIEW_BEGIN>>")
    end = preview_out.index("<<PREVIEW_END>>")
    assert "=== WORD TIMESTAMPS ===" in preview_out[begin:end], "PREVIEW emitted no words"
    assert "<<PREVIEW_" not in base_out

    print(json.dumps({
        "verdict": "WIN",
        "committed_events": len(base_events),
        "baseline_wall_s": round(base_s, 3),
        "preview_plus_segment_wall_s": round(preview_s, 3),
        "preview_markers": 2,
        "state_equivalent": True,
        "max_conf_delta": round(max_delta["conf"], 6),
        "max_avg_logprob_delta": round(max_delta["avg_logprob"], 6),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
