# Owned macOS file preparation

`madi-platform::prepared_audio` runs a small native decode helper and returns a
`PreparedAudio` ownership guard. The helper compiles the existing AVFoundation
`AudioDecode`, `Resampler` and `WavWriter` implementation, preserving audio/video
codec handling, mono 16 kHz conversion, converter tail and the 64 GiB/12-hour
bounds. No decoding implementation is forked or replaced with a different codec.

One source seam was added: `AudioDecode.toWav16k` accepts an optional
`temporaryDirectory`, whose default remains `FileManager.default.temporaryDirectory`.
Existing Swift callers are unchanged. Rust passes its newly created private
directory explicitly. Testing showed that setting `TMPDIR` alone did not move
Foundation's output into that directory, so the ownership check rejected it.
The failed synthetic outputs were identified by checksum and removed; the fixed
path is covered by native tests. This parameter changes location only: the Swift
regression compares default vs explicit-directory PCM bytes exactly.

The Rust task waits for helper exit before validating its reply. A successful
path must canonicalize beneath the guard's directory and contain a nonempty,
canonical PCM16 mono 16 kHz WAV header and payload. A symlink or external path is
rejected without deleting the target. The API has no constructor from an
arbitrary path, so it cannot treat the user's original input as owned scratch.

Cancellation and owner drop signal a worker that kills/reaps the helper before
dropping its directory. Cancelling an await preserves its completion handle.
An already-completed result may race cancellation; its returned guard still owns
cleanup. Native errors retain domain/code/reason for the future localized product
mapper; internal error details are not UI copy.

`PreparedRegistry` accepts only returned guards. A core `RemovePreparedFile` effect
can release a known guard once; a foreign or stale path is a no-op, never an
arbitrary filesystem removal. The future executor must retain the guard while
its engine uses the WAV and release it after engine teardown. It must also drop
late successful imports rejected by the session generation.

The Cargo build script compiles the helper for macOS 14+ on arm64/x86_64 using
Xcode's Swift compiler. `development_helper()` returns the local build artifact
for tests/probes only. Tauri now bundles/ad-hoc signs the helper and resolves it
beside the executable; see [native decoder package](NATIVE_DECODER_PACKAGE.md). Windows decoding is not
implemented; no Windows codec support is implied by cross-platform compilation.

Five native Rust regressions cover concurrent non-silent stereo conversion,
separate output ownership, original preservation, empty-file errors, cancellation,
drop cleanup and rejected foreign/symlinked paths. Existing Swift decode tests
also pass, including exact default/explicit-directory PCM equivalence and failure
cleanup. The headless `engine_file_smoke ... --decode` probe successfully prepared
the public JFK clip, ran the real Metal ASR engine, delivered 22 words/26 JSONL
events and removed both preparation and engine scratch. This is not yet a Tauri
file-picker/session/UI or full codec-corpus pass.
