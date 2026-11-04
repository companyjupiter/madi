# Setup and presentation preferences

The Tauri candidate restores the original start-screen choices and transcript
presentation before showing its content. Its setup/presentation adapter reads ten keys from
`com.companyjupiter.madi` on macOS: `languageTokenID`, `translateTargets`,
`meetingMode`, `diarizeEnabled`, `fixedSpeakerCount`, `audioSource`, `uiLanguage`,
`appearance`, `transcriptViewMode`, and `transcriptFontSize`; seven session keys
are now added as documented in `SETTINGS_CONTRACT.md`. The Swift domain is
never written. A valid `preferences.json` in the isolated Tauri configuration
directory takes precedence; an invalid file is retained and reported.

This is a connected implementation candidate. Actual native UI, first-paint
appearance, real-user migration, full Settings UI and OS relaunch acceptance are
**NOT_RUN**. The last computer-use operation was refused because the Mac was
locked; these checks do not bypass that boundary. Windows uses the same isolated
store with default values until native product integration is implemented.

Schema 2 now adds session/settings values and preserves transient Settings
language/overlap semantics across unrelated saves. Its expanded 725-case gate,
version-1 migration, supported command boundary and remaining UI/consumer work
are documented in `SETTINGS_CONTRACT.md`. The evidence below also records the
initial 432-case setup/presentation revision; it is historical, not the latest
full Settings acceptance.

## Original restoration rules

Loading a saved meeting mode does not apply its preset again: a user override of
speaker count or diarization survives. Selecting a mode does apply its preset.
The removed one-speaker value restores separation off only if `diarizeEnabled`
was never written. Foundation's integer/string/bool/double conversions are used,
including the difference between absence and an explicit false or zero.

Translation targets are restored as the original Swift set, including four
choices saved by Settings and unknown legacy strings. The start-screen picker
still limits new additions to three and removes its known input language on an
explicit language change. Canonically equal Unicode strings are deduplicated,
retaining the first spelling. Positive unknown language tokens survive natively
into ASR configuration while their UI label remains Auto, matching Swift.

The display language, appearance, content/detail mode and font size survive
relaunch. Font-size restoration does not clamp; the smaller/larger actions apply
the original `max(12, size - 2)` / `min(34, size + 2)` expressions. The label uses
integer truncation. Malformed nonfinite sizes are rejected instead of silently
rewriting the preference file. Selected file paths, device IDs and revisions are
transient and are never serialized into this file.

## Ordering and lifetime

One native worker owns the setup/presentation state, file selection, and atomic
preference writes. It commits a temporary file before publishing changed state.
Failed writes preserve the active snapshot and native file authority. A first
explicit durable choice is saved even when equal to the imported value, so a
later change in the original app cannot override that choice. Selecting a file
or microphone alone does not create a preference file unless it changes the
persisted audio source.

Accepted commands survive canceled IPC replies. App shutdown joins the owner,
then file/workspace/model cleanup. The frontend subscribes before reading the
initial snapshot and rejects older revisions. Starting a staged file waits for
its queued setup choices; native file admission remains owned if its caller
disappears. The model-optional Windows shutdown path now joins these owners too.

On macOS, appearance uses the main window's `NSAppearanceCustomization`, not
Tauri's app-wide `set_theme`. This follows Swift's scene-level preference and
leaves standalone native dialogs governed by their original appearance source.
The window background is read from the effective window appearance. Windows
uses Tauri's window theme. Native light/dark/system transitions remain unverified.
URL language/theme overrides are transient capture aids and never persisted.

## Evidence

- Live extracted Swift initializers and actual SwiftUI AppStorage getters match
  the Foundation Rust adapter and portable core in 432 cases / 3,024 font-step
  states. Cases include absence, legacy migration, all presets with overrides,
  coercions, four targets, Unicode canonical equality, unknown 64-bit tokens and
  font boundaries. The oracle uses volatile synthetic domains only.
- The portable gate compares a pinned Swift-normalized fixture and exact result
  hash; updating it requires `--update-reference` and a new live Swift comparison.
  Negative-zero bits are carried explicitly because Foundation JSON prints -0 as 0.
- Local macOS Rust tests pass 84 cases (11 core / 59 platform / 14 protocol),
  including real-file retention, failed commits, canceled replies, shutdown joins,
  transient authority exclusion, equal-value first save and isolated relaunch.
- ASR launch configuration still matches its existing live Swift reference.
- The debug macOS app and strict relocated-package check pass with all 16 direct
  notices. A synthetic preference save/reload then supplies the actual relocated
  decoder/Metal ASR owner: 22 JFK words, archive/workspace checks and five exports
  pass with source/model preservation and owned temporary cleanup. This is a
  headless native admission test, not a Tauri IPC or actual app relaunch test.
  See `../evidence/macos-preferences-2026-11-04.json`.

Run `python3 scripts/check_preferences_parity.py` on macOS, or append
`--rust-only` to verify portable restoration without Swift. Both paths are wired
into desktop CI. None of these synthetic/CLI gates substitutes for native
interaction or visual parity.
