#!/usr/bin/env python3
# Offline reader for VAD_DUMP files (per-window emb + raw silero frame probs).
# Computes the speech-retention curve vs VAD_PROB from ONE encoder pass — used
# for the GT-less natural KO recordings (how aggressively each threshold prunes
# real speech) and to validate the dump format.
#   python3 bench/vad_dump_probe.py <dump.bin> [label]
import sys, struct, numpy as np

def load(path):
    b = open(path, "rb").read()
    n, segd, fpw = struct.unpack("<III", b[:12]); off = 12
    t0 = np.frombuffer(b, "<f4", n, off).copy(); off += 4 * n
    emb = np.frombuffer(b, "<f4", n * segd, off).reshape(n, segd).copy(); off += 4 * n * segd
    pf = np.frombuffer(b, "<f4", n * fpw, off).reshape(n, fpw).copy()
    return n, segd, fpw, t0, emb, pf

def main():
    path = sys.argv[1]
    label = sys.argv[2] if len(sys.argv) > 2 else path
    n, segd, fpw, t0, emb, pf = load(path)
    frame_s = 0.032
    sp_gate = 0.15            # DIAR_VAD_SP default: window kept if speech-sec >= 0.15
    win_speech = pf.shape[1] * frame_s
    total_audio_win_s = n * 1.5
    print(f"\n== {label} ==  windows={n} emb_d={segd} frames/win={fpw}  (~{total_audio_win_s:.0f}s windowed)")
    print(f"{'VAD_PROB':>8} | {'speech_s':>9} {'%frames':>8} | {'win_kept':>8} {'%win':>6}")
    print("-" * 50)
    rows = []
    for thr in [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.95]:
        sp_frames = (pf >= thr).sum()
        speech_s = sp_frames * frame_s
        pct_frames = 100.0 * sp_frames / pf.size
        win_sp = (pf >= thr).sum(axis=1) * frame_s         # per-window speech-sec
        win_kept = int((win_sp >= sp_gate).sum())
        pct_win = 100.0 * win_kept / n
        rows.append((thr, speech_s, pct_frames, win_kept, pct_win))
        print(f"{thr:>8.2f} | {speech_s:>9.1f} {pct_frames:>7.1f}% | {win_kept:>8d} {pct_win:>5.1f}%")
    # knee: prob where retained windows first drop below 90% of the prob=0.1 baseline
    base = rows[0][3]
    knee = next((thr for thr, _, _, wk, _ in rows if wk < 0.90 * base), None)
    print(f"baseline windows@0.1={base}; 90%-retention knee at VAD_PROB={knee}")

if __name__ == "__main__":
    main()
