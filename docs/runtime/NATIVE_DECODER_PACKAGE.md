# Native decoder package

The macOS parity `.app` now contains `Contents/MacOS/madi-audio-decode` beside
its main executable. `scripts/prepare_desktop_native.mjs` asks Cargo for the
actual platform build-script output, stages the helper in ignored `out/`, and
records its size/hash. It never edits source files. Tauri dev/build hooks run
this preparation; direct Cargo desktop builds must run it first, as CI does.

The macOS configuration uses Tauri's
[external binary convention](https://v2.tauri.app/develop/sidecar/) with the
target-triple suffix, so the helper is copied beside the executable in both
debug output and the `.app`. Minimum macOS is 14.0, matching the Swift package
and helper deployment target. Signing is explicitly ad-hoc for this debug-only
harness. Apple Silicon is locally exercised; Intel/universal packaging still
needs its own build/device evidence. Windows has no native decoder and stages
no fake helper.

`prepared_audio::bundled_helper()` resolves only the executable's adjacent
helper, rejects an escaped symlink/non-executable, and has no Cargo-output or
PATH fallback. Host setup validates this installed resource before showing its
window. The `--native-helper-path` diagnostic exits before creating native UI;
it lets the package check exercise the same runtime resolver. No shell plugin
or frontend process-launch permission is added.

`scripts/check_desktop_package_parity.py` verifies the bundle and nested code
with deep/strict codesign checks, confirms an ad-hoc signature, copies the `.app`
outside the repository, and executes the copied diagnostic/helper with a system
PATH and unrelated cwd. A synthetic one-second input becomes valid 16 kHz mono
PCM16 and the original bytes remain unchanged. Temporarily hiding only the copied
helper makes resolution fail with ENOENT; restoring it restores signature validity.
The script archives the candidate with `ditto` and records its hash. It does not
open the UI or claim notarization, ASR-engine bundling or a product release.

CI now performs this macOS package check in addition to standalone executable
checks. Models, actual ASR/LLM executables/assets, storage, live capture and the
Tauri transcript view still require integration. This decoder package closes
only the development-helper-path dependency.
