#!/usr/bin/env python3
"""Focused diarization evaluation for 3-4 speaker panel-style audio.

The existing full_bench.py is the broad regression gate. This tool is the
triage gate for the common product complaint: a 3-4 person YouTube/panel clip
collapses to too few speakers under auto-K.

Examples:
  python3 bench/diar_panel_eval.py --vox-id migzj --vox-id jnivh --speakers-from-ref --live
  python3 bench/diar_panel_eval.py --audio panel.wav --ref panel.rttm --id panel --speakers 4
  python3 bench/diar_panel_eval.py --youtube-url 'https://youtu.be/...' --ref panel.rttm --id panel --speakers 4
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]  # engine/metal
BENCH = ROOT / "bench"
RUNS = BENCH / "runs"
VOX = Path("~/Downloads/benchmark_samples/voxconverse/dev").expanduser()
VOX_AUDIO = Path("~/Downloads/benchmark_samples/audio").expanduser()


@dataclass
class Case:
    case_id: str
    audio: Path | None
    ref: Path | None
    speakers: int | None
    youtube_url: str | None = None


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(2)


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, text=True, capture_output=True, **kw)


def require(path: Path, label: str) -> None:
    if not path.exists():
        die(f"missing {label}: {path}")


def ref_speakers(path: Path) -> int:
    speakers = set()
    with path.open() as f:
        for line in f:
            if line.startswith("SPEAKER"):
                parts = line.split()
                if len(parts) > 7:
                    speakers.add(parts[7])
    return len(speakers)


def ref_recording_id(path: Path) -> str:
    with path.open() as f:
        for line in f:
            if line.startswith("SPEAKER"):
                parts = line.split()
                if len(parts) > 1:
                    return parts[1]
    return path.stem


def download_youtube(url: str, out_dir: Path, case_id: str) -> Path:
    yt = shutil.which("yt-dlp")
    if not yt:
        die("yt-dlp not found; install it or pass --audio")
    stem = out_dir / f"{case_id}.yt"
    p = run([yt, "-f", "ba", "-o", str(stem) + ".%(ext)s", url])
    if p.returncode != 0:
        die("yt-dlp failed:\n" + p.stderr[-2000:])
    matches = sorted(out_dir.glob(f"{case_id}.yt.*"))
    if not matches:
        die("yt-dlp produced no audio file")
    return matches[0]


def to_wav16(src: Path, dst: Path) -> None:
    p = run(["ffmpeg", "-y", "-i", str(src), "-ar", "16000", "-ac", "1", str(dst)])
    if p.returncode != 0:
        die("ffmpeg conversion failed:\n" + p.stderr[-2000:])


def parse_engine(stdout: str) -> dict:
    info: dict[str, object] = {"engine_speakers": None, "auto_k": None, "osd_rows": 0}
    for line in stdout.splitlines():
        m = re.search(r"\[auto-K\] K=(\d+) \(silhouette ([0-9.-]+), tau ([0-9.]+)\)", line)
        if m:
            info["auto_k"] = int(m.group(1))
            info["silhouette"] = float(m.group(2))
            info["tau"] = float(m.group(3))
        m = re.search(r"\[osd\] (\d+) overlap", line)
        if m:
            info["osd_rows"] = int(m.group(1))
        m = re.search(r"-> (\d+) speaker\(s\)|\u2192 (\d+) speaker\(s\)", line)
        if m:
            info["engine_speakers"] = int(m.group(1) or m.group(2))
    return info


def parse_md_eval(stdout: str) -> dict:
    out: dict[str, float | None] = {
        "scored": None,
        "miss": None,
        "fa": None,
        "conf": None,
        "der": None,
    }
    pats = {
        "scored": r"SCORED SPEAKER TIME =([0-9.]+)",
        "miss": r"MISSED SPEAKER TIME =([0-9.]+)",
        "fa": r"FALARM SPEAKER TIME =([0-9.]+)",
        "conf": r"SPEAKER ERROR TIME =([0-9.]+)",
        "der": r"OVERALL SPEAKER DIARIZATION ERROR = ([0-9.]+)",
    }
    for k, pat in pats.items():
        m = re.search(pat, stdout)
        if m:
            out[k] = float(m.group(1))
    return out


def score(ref: Path, sys_rttm: Path) -> dict:
    p = run(["perl", str(BENCH / "md-eval.pl"), "-c", "0.25", "-r", str(ref), "-s", str(sys_rttm)])
    if p.returncode != 0 and not p.stdout:
        die("md-eval failed:\n" + p.stderr[-2000:])
    return parse_md_eval(p.stdout)


def write_rttm(labels: dict[float, tuple[int, float]], path: Path, fid: str) -> None:
    with path.open("w") as f:
        for t in sorted(labels):
            sid, dur = labels[t]
            f.write(f"SPEAKER {fid} 1 {t:.3f} {dur:.3f} <NA> <NA> spk{sid} <NA> <NA>\n")


def live_feed(wav: Path, out_dir: Path, seg_sec: float, overlap_sec: float) -> str:
    p = run([
        "ffprobe", "-v", "error", "-show_entries", "format=duration",
        "-of", "default=nk=1:nw=1", str(wav),
    ])
    if p.returncode != 0:
        die("ffprobe failed:\n" + p.stderr[-2000:])
    dur = float(p.stdout.strip())
    jobs = []
    i = 0
    while i * seg_sec < dur:
        s = max(i * seg_sec - (overlap_sec if i > 0 else 0), 0)
        e = min(i * seg_sec + seg_sec, dur)
        seg = out_dir / f"seg{i:05d}.wav"
        q = run([
            "ffmpeg", "-y", "-loglevel", "error", "-ss", str(s), "-t", str(e - s),
            "-i", str(wav), "-ar", "16000", "-ac", "1", str(seg),
        ])
        if q.returncode != 0:
            die("ffmpeg segmenting failed:\n" + q.stderr[-2000:])
        jobs.append((s, seg))
        i += 1
    return "".join(f"{s} {p}\n" for s, p in jobs) + "FLUSH\n"


def eval_live_case(
    case: Case,
    wav: Path,
    out_dir: Path,
    extra_env: dict[str, str],
    seg_sec: float,
    overlap_sec: float,
    no_recluster: bool,
) -> list[dict]:
    live_dir = out_dir / (case.case_id + (".live_norecluster" if no_recluster else ".live"))
    live_dir.mkdir(exist_ok=True)
    feed = live_feed(wav, live_dir, seg_sec, overlap_sec)
    env = {**os.environ, "STREAM": "1", "DIAR": "1", "STREAM_WAV_ROOTS": str(live_dir), **extra_env}
    if no_recluster:
        env["DIAR_RECLUSTER"] = "0"
    p = run([
        str(ROOT / "out/transcribe"),
        str(ROOT / "assets/model.safetensors"),
        "/dev/null",
        str(ROOT / "assets/WHISPER_BPE.bin"),
    ], cwd=str(ROOT), env=env, input=feed)
    if p.returncode != 0:
        die(f"live engine failed for {case.case_id}:\n{p.stderr[-2000:]}")

    output_lines = p.stdout.splitlines()
    last_segment_end = max((i for i, line in enumerate(output_lines) if line.strip() == "<<SEG_END>>"), default=-1)
    mid_fix_count = 0
    mid_fix_windows: set[float] = set()
    spk: dict[float, tuple[int, float]] = {}
    spkfix: dict[float, tuple[int, float]] = {}
    spkov: list[tuple[float, int, float]] = []
    for line_no, line in enumerate(output_lines):
        m = re.match(r"(SPKFIX|SPKOV|SPK) ([0-9.]+) (\d+)(?: ([0-9.]+))?(?: [0-9.]+)?$", line)
        if not m:
            continue
        if m.group(1) == "SPKOV":
            spkov.append((float(m.group(2)), int(m.group(3)), float(m.group(4) or 1.5)))
        else:
            labels = spkfix if m.group(1) == "SPKFIX" else spk
            labels[round(float(m.group(2)), 2)] = (int(m.group(3)), float(m.group(4) or 1.5))
            if m.group(1) == "SPKFIX" and line_no <= last_segment_end:
                mid_fix_count += 1
                mid_fix_windows.add(round(float(m.group(2)), 2))

    fid = ref_recording_id(case.ref) if case.ref else case.case_id
    mode_prefix = "live_norecluster" if no_recluster else "live"
    records: list[dict] = []
    streams = [("stream", spk), ("relabel", spkfix)]
    for suffix, labels in streams:
        if not labels:
            continue
        sys_rttm = out_dir / f"{case.case_id}.{mode_prefix}.{suffix}.rttm"
        write_rttm(labels, sys_rttm, fid)
        rec = {
            "id": case.case_id,
            "mode": f"{mode_prefix}_{suffix}",
            "speakers_ref": ref_speakers(case.ref) if case.ref else case.speakers,
            "speakers_hint": case.speakers,
            "engine_speakers": len({sid for sid, _ in labels.values()}),
            "auto_k": None,
            "osd_rows": 0,
            "mid_fix_count": mid_fix_count,
            "mid_fix_windows": len(mid_fix_windows),
            "rttm": str(sys_rttm),
        }
        if case.ref:
            rec.update(score(case.ref, sys_rttm))
        records.append(rec)
    if spkfix and spkov:
        sys_rttm = out_dir / f"{case.case_id}.{mode_prefix}.relabel_osd.rttm"
        write_rttm(spkfix, sys_rttm, fid)
        with sys_rttm.open("a") as f:
            for t, sid, dur in spkov:
                f.write(f"SPEAKER {fid} 1 {t:.3f} {dur:.3f} <NA> <NA> spk{sid} <NA> <NA>\n")
        rec = {
            "id": case.case_id,
            "mode": f"{mode_prefix}_relabel_osd",
            "speakers_ref": ref_speakers(case.ref) if case.ref else case.speakers,
            "speakers_hint": case.speakers,
            "engine_speakers": len({sid for sid, _ in spkfix.values()}),
            "auto_k": None,
            "osd_rows": len(spkov),
            "mid_fix_count": mid_fix_count,
            "mid_fix_windows": len(mid_fix_windows),
            "rttm": str(sys_rttm),
        }
        if case.ref:
            rec.update(score(case.ref, sys_rttm))
        records.append(rec)
    return records


def eval_case(case: Case, mode: str, wav: Path, out_dir: Path, extra_env: dict[str, str]) -> dict:
    sys_rttm = out_dir / f"{case.case_id}.{mode}.rttm"
    args = [
        str(ROOT / "out/transcribe"),
        str(ROOT / "assets/model.safetensors"),
        str(wav),
        str(ROOT / "assets/WHISPER_BPE.bin"),
        str(sys_rttm),
    ]
    env = {**os.environ, "DIAR_ONLY": "1", **extra_env}
    if mode == "forced":
        if not case.speakers:
            die(f"{case.case_id}: forced mode requires --speakers or --speakers-from-ref")
        args.append(str(case.speakers))
        env["DIAR_K"] = str(case.speakers)
    p = run(args, cwd=str(ROOT), env=env)
    if p.returncode != 0:
        die(f"engine failed for {case.case_id}/{mode}:\n{p.stderr[-2000:]}")
    rec = {
        "id": case.case_id,
        "mode": mode,
        "speakers_ref": ref_speakers(case.ref) if case.ref else case.speakers,
        "speakers_hint": case.speakers,
        "rttm": str(sys_rttm),
        **parse_engine(p.stdout),
    }
    if case.ref:
        rec.update(score(case.ref, sys_rttm))
    return rec


def build_cases(args: argparse.Namespace) -> list[Case]:
    cases: list[Case] = []
    for vid in args.vox_id:
        ref = VOX / f"{vid}.rttm"
        audio = VOX_AUDIO / f"{vid}.wav"
        require(ref, "VoxConverse RTTM")
        require(audio, "VoxConverse audio")
        speakers = ref_speakers(ref) if args.speakers_from_ref else args.speakers
        cases.append(Case(vid, audio, ref, speakers))
    if args.audio:
        audio = Path(args.audio).expanduser()
        require(audio, "audio")
        ref = Path(args.ref).expanduser() if args.ref else None
        if ref:
            require(ref, "RTTM")
        speakers = ref_speakers(ref) if ref and args.speakers_from_ref else args.speakers
        case_id = args.id or (ref_recording_id(ref) if ref else audio.stem)
        cases.append(Case(case_id, audio, ref, speakers))
    if args.youtube_url:
        ref = Path(args.ref).expanduser() if args.ref else None
        if ref:
            require(ref, "RTTM")
        speakers = ref_speakers(ref) if ref and args.speakers_from_ref else args.speakers
        case_id = args.id or (ref_recording_id(ref) if ref else "youtube_panel")
        cases.append(Case(case_id, None, ref, speakers, args.youtube_url))
    if not cases:
        die("pass --vox-id, --audio, or --youtube-url")
    return cases


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--vox-id", action="append", default=[], help="VoxConverse dev id, e.g. migzj")
    ap.add_argument("--audio", help="local audio/video file")
    ap.add_argument("--youtube-url", help="download a YouTube audio track with yt-dlp")
    ap.add_argument("--ref", help="reference RTTM for --audio/--youtube-url")
    ap.add_argument("--id", help="case id for local/YouTube input")
    ap.add_argument("--speakers", type=int, help="known speaker count for forced mode")
    ap.add_argument("--speakers-from-ref", action="store_true", help="derive forced-K from reference RTTM")
    ap.add_argument("--mode", choices=["auto", "forced", "both"], default="both")
    ap.add_argument("--live", action="store_true", help="also score live STREAM path")
    ap.add_argument("--live-no-recluster", action="store_true", help="also score live path with DIAR_RECLUSTER=0")
    ap.add_argument("--seg", type=float, default=10.0, help="live segment seconds")
    ap.add_argument("--overlap", type=float, default=3.0, help="live left-context overlap seconds")
    ap.add_argument("--env", action="append", default=[], help="extra engine env, KEY=VALUE")
    ap.add_argument("--out-dir", default=None)
    args = ap.parse_args()

    require(ROOT / "out/transcribe", "engine binary")
    require(ROOT / "assets/model.safetensors", "Whisper model")
    require(ROOT / "assets/WHISPER_BPE.bin", "BPE")
    require(BENCH / "md-eval.pl", "md-eval.pl")

    extra_env = {}
    for item in args.env:
        if "=" not in item:
            die(f"--env expects KEY=VALUE: {item}")
        k, v = item.split("=", 1)
        extra_env[k] = v

    out_dir = Path(args.out_dir) if args.out_dir else RUNS / ("diar_panel_" + time.strftime("%Y%m%d_%H%M%S"))
    out_dir.mkdir(parents=True, exist_ok=True)
    scratch = out_dir / "scratch"
    scratch.mkdir(exist_ok=True)

    modes = ["auto", "forced"] if args.mode == "both" else [args.mode]
    records = []
    for case in build_cases(args):
        src = case.audio
        if case.youtube_url:
            src = download_youtube(case.youtube_url, scratch, case.case_id)
        assert src is not None
        # transcribe.zig uses the WAV basename as the RTTM file id. Keep the stem
        # exactly equal to the reference id (e.g. "migzj"), or md-eval treats the
        # whole system RTTM as a different recording and scores 100% miss.
        wav = scratch / f"{case.case_id}.wav"
        to_wav16(src, wav)
        for mode in modes:
            if mode == "forced" and not case.speakers:
                continue
            rec = eval_case(case, mode, wav, out_dir, extra_env)
            records.append(rec)
            print(json.dumps(rec, ensure_ascii=False))
        if args.live:
            for rec in eval_live_case(case, wav, out_dir, extra_env, args.seg, args.overlap, False):
                records.append(rec)
                print(json.dumps(rec, ensure_ascii=False))
        if args.live_no_recluster:
            for rec in eval_live_case(case, wav, out_dir, extra_env, args.seg, args.overlap, True):
                records.append(rec)
                print(json.dumps(rec, ensure_ascii=False))

    with (out_dir / "results.jsonl").open("w") as f:
        for rec in records:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    lines = [
        "# Diarization Panel Eval",
        "",
        "| id | mode | ref spk | engine spk | auto-K | DER | miss | FA | conf | osd | mid fixes |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for r in records:
        def fmt(k: str) -> str:
            v = r.get(k)
            return "" if v is None else (f"{v:.2f}" if isinstance(v, float) else str(v))
        lines.append(
            f"| {r['id']} | {r['mode']} | {fmt('speakers_ref')} | {fmt('engine_speakers')} | "
            f"{fmt('auto_k')} | {fmt('der')} | {fmt('miss')} | {fmt('fa')} | {fmt('conf')} | "
            f"{fmt('osd_rows')} | {fmt('mid_fix_windows')} |"
        )
    (out_dir / "summary.md").write_text("\n".join(lines) + "\n")
    print(f"summary: {out_dir / 'summary.md'}")


if __name__ == "__main__":
    main()
