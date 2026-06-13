# tools/

Self-contained utilities that consume the engine's structured event contract
([`docs/EVENTS.md`](../docs/EVENTS.md)). Each is verifiable standalone against a
checked-in fixture (`web/fixtures/*.events.jsonl`).

## `srt_broadcast.py` — broadcast-grade SRT

Groups `word` events into subtitle cues that satisfy broadcast reading
constraints, then **self-verifies conformance** (the check is the point):

- **Hard** (always satisfiable by segmentation, build fails on violation): ≤ 2
  lines, ≤ `--max-line` display cells/line, ≤ `--max-dur` s, no overlap.
- **Soft** (speech-density limited, reported but not failed): reading speed
  `--cps` and `--min-dur` — a passage spoken faster than CPS can't slow down
  without overlapping the next cue.

Display width is **full-width aware**: Hangul/CJK count as 2 cells, so `--max-line
42` ≈ 42 Latin or ~21 Korean characters — matching Korean broadcast practice.

```sh
python3 tools/srt_broadcast.py web/fixtures/devops_ko.events.jsonl --out out.srt
python3 tools/srt_broadcast.py web/fixtures/jfk3.events.jsonl --cps 17 --max-line 42
```

Verified: devops_ko (KO, 164 cues), jfk3 (EN, 10), devops_ko_biased (106) all
pass the hard rules. The macOS app's `Exporters.srt` can adopt this segmentation.

## `captions.py` — multi-format export (editor-compatible)

Reuses the same cue segmentation and renders the formats professional editors
import natively, plus a shareable HTML transcript:

| format | extension | target |
|---|---|---|
| SubRip | `.srt` | DaVinci Resolve, Premiere, Final Cut — universal |
| WebVTT | `.vtt` | browsers (`<track>`), most editors |
| iTunes Timed Text / TTML | `.itt` | **Final Cut Pro** & **Premiere** native captions |
| FCPXML | `.fcpxml` | **Final Cut Pro** project with a caption track |
| HTML | `.html` | self-contained interactive transcript (speaker colors, timestamps, low-confidence amber, hover for confidence) |

Every XML format is validated (ElementTree parse) before writing.

```sh
python3 tools/captions.py web/fixtures/devops_ko.events.jsonl --out-base out \
  --fmt srt,vtt,itt,fcpxml,html --fps 30 --lang ko
```

Verified: all 5 formats generate for KO/EN/biased fixtures; `.itt`/`.fcpxml` are
well-formed XML with one caption per cue; the HTML carries every word span with
its confidence and speaker attribution.
