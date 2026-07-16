#!/usr/bin/env python3
"""Metrics for the labels a live-diarization user actually sees.

Final DER hides how long a wrong speaker label remained on screen.  This
module reconstructs the visible label state from ordered SPK/SPKFIX events,
maps engine ids to reference speakers once, and measures the error exposure
between first display and the end of the live session.  FLUSH-time SPKFIX
events are intentionally excluded: they improve the saved transcript, not the
in-session experience.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path


LABEL_RE = re.compile(
    r"(SPKFIX|SPKOV|SPK) ([0-9.]+) (\d+)(?: ([0-9.]+))?(?: ([+-]?[0-9.]+))?$"
)

AMBIGUOUS_MARGIN = 0.20
SENTINEL_MARGIN = 0.999


@dataclass(frozen=True)
class ReferenceTurn:
    start: float
    end: float
    speaker: str


@dataclass(frozen=True)
class LabelEvent:
    kind: str
    time: float
    duration: float
    speaker: int
    visible_at: float
    during_flush: bool
    margin: float | None


@dataclass
class VisibleWindow:
    time: float
    duration: float
    history: list[tuple[float, int]]
    first_margin: float | None


def percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    pos = (len(ordered) - 1) * q
    lo = int(pos)
    hi = min(lo + 1, len(ordered) - 1)
    frac = pos - lo
    return ordered[lo] * (1.0 - frac) + ordered[hi] * frac


def parse_reference(path: Path) -> list[ReferenceTurn]:
    turns: list[ReferenceTurn] = []
    with path.open() as f:
        for line in f:
            parts = line.split()
            if len(parts) < 8 or parts[0] != "SPEAKER":
                continue
            start = float(parts[3])
            turns.append(ReferenceTurn(start, start + float(parts[4]), parts[7]))
    return turns


def parse_label_events(stdout: str, frontiers: list[float]) -> list[LabelEvent]:
    """Attach every engine label event to the audio frontier visible then."""
    events: list[LabelEvent] = []
    completed_segments = 0
    session_end = frontiers[-1] if frontiers else 0.0
    for raw in stdout.splitlines():
        line = raw.strip()
        if line == "<<SEG_END>>":
            completed_segments += 1
            continue
        match = LABEL_RE.fullmatch(line)
        if not match or match.group(1) == "SPKOV":
            continue
        during_flush = completed_segments >= len(frontiers)
        if during_flush or not frontiers:
            visible_at = session_end
        else:
            visible_at = frontiers[completed_segments]
        events.append(
            LabelEvent(
                kind=match.group(1),
                time=round(float(match.group(2)), 2),
                duration=float(match.group(4) or 1.5),
                speaker=int(match.group(3)),
                visible_at=visible_at,
                during_flush=during_flush,
                margin=float(match.group(5)) if match.group(5) is not None else None,
            )
        )
    return events


def overlap(a0: float, a1: float, b0: float, b1: float) -> float:
    return max(0.0, min(a1, b1) - max(a0, b0))


def dominant_reference(window: VisibleWindow, turns: list[ReferenceTurn]) -> str | None:
    weights: dict[str, float] = {}
    end = window.time + window.duration
    for turn in turns:
        shared = overlap(window.time, end, turn.start, turn.end)
        if shared > 0:
            weights[turn.speaker] = weights.get(turn.speaker, 0.0) + shared
    if not weights:
        return None
    return max(sorted(weights), key=weights.get)


def best_bijective_mapping(
    windows: list[VisibleWindow], turns: list[ReferenceTurn]
) -> dict[int, str]:
    """Maximum-overlap one-to-one system-id to reference-speaker mapping."""
    speakers = sorted({turn.speaker for turn in turns})
    system_ids = sorted({window.history[-1][1] for window in windows})
    if not speakers or not system_ids:
        return {}

    weights: dict[tuple[int, str], float] = {}
    for window in windows:
        sid = window.history[-1][1]
        end = window.time + window.duration
        for turn in turns:
            shared = overlap(window.time, end, turn.start, turn.end)
            if shared > 0:
                key = (sid, turn.speaker)
                weights[key] = weights.get(key, 0.0) + shared

    # dp[reference-mask] = (score, system-id -> reference-speaker mapping).
    # Leaving a transient/extra system id unmapped is deliberate: mapping two
    # visible ids to one person would hide the exact over-split UX failure.
    dp: dict[int, tuple[float, dict[int, str]]] = {0: (0.0, {})}
    for sid in system_ids:
        next_dp = dict(dp)
        for mask, (score, mapping) in dp.items():
            for ref_index, ref_speaker in enumerate(speakers):
                bit = 1 << ref_index
                if mask & bit:
                    continue
                candidate_score = score + weights.get((sid, ref_speaker), 0.0)
                candidate_mask = mask | bit
                previous = next_dp.get(candidate_mask)
                if previous is None or candidate_score > previous[0]:
                    candidate = dict(mapping)
                    candidate[sid] = ref_speaker
                    next_dp[candidate_mask] = (candidate_score, candidate)
        dp = next_dp
    return max(dp.values(), key=lambda item: (item[0], len(item[1])))[1]


def visible_windows(events: list[LabelEvent]) -> tuple[list[VisibleWindow], int]:
    windows: dict[float, VisibleWindow] = {}
    peak_speakers = 0

    def update_peak() -> None:
        nonlocal peak_speakers
        current = {window.history[-1][1] for window in windows.values()}
        peak_speakers = max(peak_speakers, len(current))

    for event in events:
        if event.during_flush:
            continue
        if event.kind == "SPK":
            # TranscriptStore keeps every SPK and its stable sort makes the
            # first covering label authoritative.  Mirror that first-visible
            # behavior instead of silently replacing it with a later duplicate.
            if event.time not in windows:
                windows[event.time] = VisibleWindow(
                    time=event.time,
                    duration=event.duration,
                    history=[(event.visible_at, event.speaker)],
                    first_margin=event.margin,
                )
                update_peak()
            continue

        # TranscriptStore applies SPKFIX to labels within 110 ms, not only to an
        # exact floating-point key.  One correction can therefore touch several
        # clipped pieces from the same diarization window.
        touched = [
            window for start, window in windows.items() if abs(start - event.time) < 0.11
        ]
        for window in touched:
            last_at, last_speaker = window.history[-1]
            if last_speaker == event.speaker:
                continue
            at = max(last_at, event.visible_at)
            window.history.append((at, event.speaker))
        if touched:
            update_peak()
    return sorted(windows.values(), key=lambda window: window.time), peak_speakers


def analyze_live_ux(stdout: str, frontiers: list[float], reference: Path) -> dict:
    events = parse_label_events(stdout, frontiers)
    windows, peak_speakers = visible_windows(events)
    turns = parse_reference(reference)
    mapping = best_bijective_mapping(windows, turns)
    session_end = frontiers[-1] if frontiers else 0.0

    covered = 0
    first_correct = 0
    final_correct = 0
    initially_wrong = 0
    corrected = 0
    unresolved = 0
    label_changes = 0
    changed_windows = 0
    wrong_visible = 0.0
    total_visible = 0.0
    first_latencies: list[float] = []
    correction_latencies: list[float] = []
    settle_latencies: list[float] = []
    margin_buckets: dict[str, list[bool]] = {
        "ambiguous": [],
        "confident": [],
        "sentinel": [],
    }

    for window in windows:
        target = dominant_reference(window, turns)
        if target is None:
            continue
        covered += 1
        history = window.history
        first_at = history[0][0]
        first_latencies.append(max(0.0, first_at - (window.time + window.duration)))
        total_visible += max(0.0, session_end - first_at)
        correctness = [mapping.get(speaker) == target for _, speaker in history]
        if window.first_margin is not None:
            if window.first_margin < AMBIGUOUS_MARGIN:
                bucket = "ambiguous"
            elif window.first_margin >= SENTINEL_MARGIN:
                # diarAssign emits 1.0 both before a second centroid exists and
                # on a speaker birth. It is a control-state sentinel, not high
                # acoustic confidence; keep it separate from real margins.
                bucket = "sentinel"
            else:
                bucket = "confident"
            margin_buckets[bucket].append(correctness[0])
        first_correct += int(correctness[0])
        final_correct += int(correctness[-1])
        label_changes += len(history) - 1
        if len(history) > 1:
            changed_windows += 1
            settle_latencies.append(history[-1][0] - first_at)

        for index, (at, _) in enumerate(history):
            next_at = history[index + 1][0] if index + 1 < len(history) else session_end
            if not correctness[index]:
                wrong_visible += max(0.0, next_at - at)

        if correctness[0]:
            continue
        initially_wrong += 1
        if not correctness[-1]:
            unresolved += 1
            continue
        # Stable-correct means no later label transition returns this window to
        # a wrong identity.  It is stricter and more user-faithful than the first
        # fleeting correct label.
        stable_index = len(correctness) - 1
        while stable_index > 0 and correctness[stable_index - 1]:
            stable_index -= 1
        correction_latencies.append(history[stable_index][0] - first_at)
        corrected += 1

    duration_min = session_end / 60.0 if session_end > 0 else 0.0
    reference_speakers = len({turn.speaker for turn in turns})
    final_visible = len({window.history[-1][1] for window in windows})

    def rate(numerator: int, denominator: int) -> float | None:
        return (100.0 * numerator / denominator) if denominator else None

    def bucket_error(name: str) -> float | None:
        values = margin_buckets[name]
        return rate(sum(not correct for correct in values), len(values))

    return {
        "ux_windows": len(windows),
        "ux_ref_windows": covered,
        "first_label_latency_p50_sec": percentile(first_latencies, 0.50),
        "first_label_latency_p90_sec": percentile(first_latencies, 0.90),
        "immediate_correct_pct": rate(first_correct, covered),
        "final_mid_correct_pct": rate(final_correct, covered),
        "initially_wrong_windows": initially_wrong,
        "corrected_windows": corrected,
        "unresolved_wrong_windows": unresolved,
        "unresolved_initial_wrong_pct": rate(unresolved, initially_wrong),
        "time_to_correct_p50_sec": percentile(correction_latencies, 0.50),
        "time_to_correct_p90_sec": percentile(correction_latencies, 0.90),
        "wrong_visible_window_sec": wrong_visible,
        "wrong_visible_ratio_pct": (100.0 * wrong_visible / total_visible) if total_visible else None,
        "label_changes": label_changes,
        "changed_windows": changed_windows,
        "label_churn_per_min": (label_changes / duration_min) if duration_min else None,
        "settle_latency_p90_sec": percentile(settle_latencies, 0.90),
        "visible_speakers_peak": peak_speakers,
        "visible_speakers_final_mid": final_visible,
        "speaker_overcount_peak": peak_speakers - reference_speakers,
        "first_margin_ambiguous_windows": len(margin_buckets["ambiguous"]),
        "first_margin_ambiguous_wrong_pct": bucket_error("ambiguous"),
        "first_margin_confident_windows": len(margin_buckets["confident"]),
        "first_margin_confident_wrong_pct": bucket_error("confident"),
        "first_margin_sentinel_windows": len(margin_buckets["sentinel"]),
        "first_margin_sentinel_wrong_pct": bucket_error("sentinel"),
    }
