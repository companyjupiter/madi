# Sovereign engine — structured event contract (`EVENTS_FILE`)

The `transcribe` engine has two output surfaces:

1. **stdout text** — the original human/Swift contract (`=== WORD TIMESTAMPS ===`,
   `[t0s-t1s] word «conf x»`, `SPK/SPKFIX/SPKOV`, `<<SEG_END>>`, `<<FLUSH_END>>`,
   `[perf]`). **Frozen** — parsed by `app/Sovereign/Engine/EngineProtocol.swift`
   and its unit tests. Never change its shape.
2. **structured events** — this document. **Opt-in**: set `EVENTS_FILE=<path>`
   and the engine writes one JSON object per line to that file, *in addition*
   to stdout (stdout stays byte-identical — verified). This is the machine
   contract the Web dashboard and any future consumer binds to.

> Why a second surface instead of changing stdout: the Swift app + tests depend
> on the text shape, and mixing JSON into the same stream would break greppable
> human output. A separate sink keeps both clean. A future Swift migration can
> switch to this file without a flag day.

## Stream shape

JSON-lines (`.jsonl`): one object per line, UTF-8, Korean text emitted raw
(unescaped ≥0x80, human-readable). Every object has a string tag `"t"`. The
stream opens with a `meta` line carrying a schema version `"v"`. Consumers
should **ignore unknown `"t"` values and unknown fields** (forward-compat).

### Field stability

Reserved fields are emitted with defaults *today* so UI can bind to the final
data model before the producing feature lands:

| field | on event | status | notes |
|---|---|---|---|
| `avg_logprob` | `seg` | **real** | mean ln(token softmax prob) — decode certainty |
| `fallback` | `seg` | **real** | `"none"` / `"collapse"` (periodic repeat) / `"logprob"` (avg_logprob<−1.0 → ts re-decode) |
| `temp` | `seg` | reserved `0.0` | only a stochastic temperature sweep would set it (deferred — not a WER mover here, see PERF_LOG P1) |
| `spk` | `word` | `-1` | diar runs after decode; resolve speaker from `spk_seg` |
| `bias_hits` | `seg` | **real** when `PROMPT` set | array of biasing terms that surfaced in the segment (absent when no prompt) |

## Event types

| `t` | when | fields |
|---|---|---|
| `meta` | once, first line | `v` (schema ver), `model`, `lang` (Whisper lang-token id; 0=auto), `sr` |
| `ready` | stream mode, model resident | — |
| `partial` | each decode batch (opt-in `PARTIALS=1`) | `t0` (s), `text` (in-progress hypothesis; superseded by the segment's `seg`) |
| `word` | each aligned word | `t0`,`t1` (global s), `conf` (0–1 softmax prob), `spk` (−1 until attributed), `text` |
| `seg` | each 30 s chunk decoded | `idx`, `t0`,`t1` (s), `dropped` (hallucination-guard), `avg_logprob`, `fallback`,`temp`, `tok_s`,`enc_ms`,`dec_ms`,`passes` (perf), `text` |
| `spk_seg` | each speaker-attributed run | `t0` (global s), `spk` (speaker id), `text` |
| `diar` | once per file/flush | `speakers` (final K), `silhouette`, `sep` (max centroid cosdist — solo-split gate signal), `tau`, `segments` (speech windows) |
| `seg_end` | stream: one job done | — |
| `flush_end` | stream: finalization done | — |

## Example

```jsonl
{"t":"meta","v":1,"model":"whisper-large-v3-turbo-q8","lang":0,"sr":16000}
{"t":"word","t0":0.332,"t1":0.499,"conf":0.9228,"spk":-1,"text":"And"}
{"t":"seg","idx":0,"t0":0.00,"t1":30.00,"dropped":false,"fallback":"none","temp":0.0,"tok_s":490.2,"enc_ms":512,"dec_ms":141,"passes":1,"text":"And so, my fellow Americans, ..."}
{"t":"diar","speakers":1,"silhouette":-2.000,"sep":0.326,"tau":0.35,"segments":22}
{"t":"spk_seg","t0":0.33,"spk":0,"text":"And so, my fellow Americans, ..."}
```

## Generating fixtures

```sh
EVENTS_FILE=web/fixtures/jfk3.events.jsonl CONF=1 DIAR=1 \
  metal/out/transcribe metal/assets/model.safetensors metal/assets/jfk3.wav metal/assets/WHISPER_BPE.bin
```

Checked-in fixtures (`web/fixtures/`) drive the dashboard offline:
`jfk3` (EN, 1 speaker), `devops_ko` (KO, announcer), `clova` (KO, dialogue).
