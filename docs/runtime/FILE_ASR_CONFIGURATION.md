# File ASR configuration

`madi_platform::asr_config` constructs a typed file-mode `Launch` from trusted
native resources and `FileSettings`. `FileSettings::from_setup` preserves the
shipping setup policy: English/Chinese/Korean/Japanese token IDs, fixed 2/3/4
speakers versus automatic 0/5+, per-count VAD threshold, independent diarization
and overlap detection, the 24 GiB encoder cache threshold, and joined vocabulary
terms. Recording configuration is a later step; live-only candidates, voiceprints
and stream roots are not enabled for file transcription.

`Resources` is not deserializable from IPC. Its paths must come from the native
model/bundle admission layer. `file_launch` validates speaker limits, finite VAD
probabilities and NUL-free vocabulary, then supplies model/WAV/BPE arguments and
the asset working directory. The caller must keep its `PreparedAudio` ownership
guard until the engine has exited. The supervisor supplies its own EVENTS_FILE;
this builder cannot select a cleanup path. Resource existence, checksum/model
admission and full session integration remain separate work.

There is one intentional difference from Swift's inherited environment: all
engine-owned mode/config keys are explicitly removed before configured values
are applied. A parent shell's `STREAM=0` still enables streaming in the engine;
stale DIAR_K, language, glossary or cache flags can likewise override the setup.
Rust clears these absent options, while preserving unrelated loader environment.
The ordinary clean app launch remains byte-equivalent to Swift's construction.

The live differential extracts `EngineProcess.Config`, its launch construction
and `SpeakerCount` properties from unchanged source. Across 601 cases, executable,
working directory, all three arguments and managed environment entries match.
The matrix covers five languages including auto, five speaker choices,
diarization/OSD on/off, memory below/at/above 24 GiB, empty/Unicode/multiline
vocabulary and raw engine defaults. Source/corpus/result hashes are pinned in
`design/parity/asr-config-reference.json`; Windows checks the same reference
without claiming to execute Swift or a Windows ASR engine.

The actual native decode → Metal ASR → teardown probe also passed with conflicting
STREAM, fixed-K, language, glossary and encoder-cache variables in its parent
environment. It produced the normal 22-word/26-event JFK result, FLUSH_END before
exit 0, no IO failures and removal of both owned scratch directories. The original
public WAV's checksum is unchanged. This is a configuration/transport smoke, not
the full session effect executor, UI parity or an ASR quality benchmark.
