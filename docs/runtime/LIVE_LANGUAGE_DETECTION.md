# Live language detection and partial Unicode

The 2026-11-10 microphone validation reproduced two independent causes of the
reported Korean corruption. The capture itself was valid 16 kHz mono PCM.

An ambiguous 1.5-second opening chose Arabic with a language-logit margin of 2.31,
but its decoded average log probability was only -1.508. The old engine locked
the language before evaluating that decode. Without a candidate whitelist it
never reconsidered the language, even for later clear Korean or public English.
Separately, a BPE token can end midway through a Korean UTF-8 scalar. Publishing
every token prefix emitted invalid bytes in partial JSONL/stdout; the same
recording's complete segment text was valid.

## Correction

Auto input probes the full language range on each committed segment. It holds
the confirmed language through ambiguous challenges, using the existing
`LANG_SWITCH_MARGIN` (default 1.0). The first candidate still uses
`LANG_LOCK_MARGIN` / `LANG_LOCK_TRIES`, but a candidate can only be confirmed
after a nonempty, nondropped decode meets the existing `LOGPROB_RESCUE` floor
(default -1.0). Failed provisional decodes publish no words or partial text.
A later segment can therefore recover without inheriting the opening guess.
Explicit language input retains its existing behavior, including an explicitly
configured candidate whitelist.

Partial JSONL and stdout use the longest complete UTF-8 prefix, withholding at
most the unfinished scalar. First/unconfirmed language decodes withhold interim
text until the committed result is available. These guards are in
`engine/metal/live_decode_policy.zig`, with the engine call sites in
`engine/metal/transcribe.zig`.

## Evidence and limits

Eight serial before/after probes use the installed Whisper model and the actual
Metal process. They cover fresh JFK, captured opening/Korean/JFK, fresh captured
Korean, bad opening/JFK, silence/JFK, repeated Korean, Korean/English/Korean and
explicit Korean. Before the fix the bad opening fixes all later languages to
Arabic; repeated Korean and explicit Korean produce malformed partial UTF-8.
Afterward all eight processes exit successfully with zero malformed UTF-8,
the weak opening is dropped, JFK recovers, and auto mode follows Korean →
English → Korean. Explicit Korean remains Korean (that case tests the setting,
not recognition quality on English audio).

Policy regressions run in the macOS parity job:

```sh
zig test engine/metal/live_decode_policy.zig -lc -target aarch64-macos.14.0
```

The rebuilt actual `.app` also transcribes the three sentences of a locally
generated `Yuna` speech fixture exactly, displays valid Korean, archives it,
exports Markdown and reopens it. Manual export now reloads the workspace list
after successful writing, so the new file appears immediately.

These observations do not establish general ASR accuracy. Low-confidence first
speech may be withheld; interim output is delayed until initial language
confirmation. Reprobe adds a decoder step per committed segment. The full live
preview/latency matrix, post-fix hardware microphone run, microphone resume and
system/mixed capture still require acceptance. The post-fix microphone attempt
was blocked by macOS ad-hoc-signature permission handling, not an ASR result.

See `../evidence/macos-native-language-2026-11-10.json`. Private microphone PCM,
transcripts and raw process output are retained only in ignored local evidence,
not repository fixtures. Only non-content comparison metadata is recorded.

## Recorded-audio validation (2026-11-22)

Microphone hardware is not required to exercise the installed Metal engine's
stream protocol. `scripts/probe_live_language.py` serially feeds existing mono
PCM16/16 kHz WAV files to a baseline and candidate, validates both stdout and
JSONL as strict UTF-8, checks committed languages and required partial output,
and compares normalized character errors when reference text is supplied.
Missing events, missing transcripts, a failed baseline process, or silently
disabling the required partials cannot count as a successful comparison.

The 27-case campaign combines seven regression scenarios with the first two
test utterances from each of ten speakers in [Zeroth-Korean](https://openslr.org/40/).
The public corpus was created by Lucas Jo / Atlas Guide and Wonkyum Lee /
Gridspace and is distributed under CC BY 4.0; the pinned
[Hugging Face mirror](https://huggingface.co/datasets/kresnik/zeroth_korean/tree/1fe9378)
provides the test parquet. Selection was fixed before inference. The 20 public
utterances total 195.694 seconds. Both binaries make 91 character errors over
782 normalized reference characters (11.6368% CER); no individual public case
regresses. This is a small regression sample, not a general accuracy estimate.
Across all 27 cases, malformed UTF-8 occurs in 18 baseline cases and zero
candidate cases. Repeated and explicitly selected Korean still emit partials.
Both rejected-opening cases recover to later Korean/English, and automatic
mode follows Korean/English changes without forcing the translation targets.

An M4A made from the first selected public utterance also exercises the native
file picker, decoder, actual transcription, whole-line editing in detail mode,
automatic archive, manual Markdown export, immediate workspace refresh and
reopen. Native microphone permission/capture/resume, system or mixed audio,
human listening quality and the complete live latency matrix remain NOT_RUN.
A video/audio file can test decoding and recognition; it does not establish
that a physical microphone or screen-audio capture is working.

Example local manifest (paths and optional reference text stay local):

```json
{"cases":[{"name":"repeated_korean","files":["/path/speech.wav","/path/speech.wav"],"languages":[50264,50264],"require_all_text":true,"min_partials":1}]}
```

```sh
python3 scripts/probe_live_language.py \
  --engine engine/metal/out/transcribe --baseline-engine /path/baseline/transcribe \
  --model "$HOME/Library/Application Support/Madi/model.q8.safetensors" \
  --assets /path/assets-small --manifest /path/cases.json --output out/language-probe
```

Use a new output directory for each run. Raw stdout, JSONL and audio references
may contain private speech and must remain outside committed evidence. The
receipt `../evidence/macos-recorded-language-2026-11-22.json` records hashes,
aggregate results and acceptance limits without private transcripts.
