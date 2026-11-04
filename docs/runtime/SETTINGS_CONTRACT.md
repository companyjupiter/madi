# Settings command and persistence boundary

The original Settings scene contains Recording, Save, conditional Translation,
Glossary and Model tabs. Its 460×380 content frame plus SwiftUI padding is the
layout baseline. The isolated Tauri Settings window now connects these controls
to the session-setting, presentation, workspace, glossary and model owners.
Actual macOS checks cover opening, tab selection, close/reopen, language events,
auto-save, glossary changes, folder-panel cancellation and Finder selection.
**Full visual parity, live capture and caption-overlay acceptance remain open.**

## Different entry points have different behavior

`ContentView.setLanguage` persists the token and removes self-translation.
`SettingsView` instead binds directly to `session.languageTokenID`; this changes
the current session without writing `languageTokenID` or removing an output.
Later unrelated saves must not accidentally make that transient choice durable.
The native owner therefore writes the keys affected by each intent, rather than
serializing every current session value after any click.

The start screen permits three output additions. Settings can enable all four,
including the selected input language; the translation consumer excludes the
source language later. Both entry points share the same runtime target set.
Selecting a microphone in Settings only assigns the transient device ID; the
start-screen selector also exits system-only capture. `osd` starts true, remains
session-only, and now travels directly through `FileSettings::from_setup` into
`OSD` in the native file engine environment. No host hardcoded override remains.

## Stored values and version migration

Schema 2 adds a `settings` object alongside the existing setup and presentation
fields. A schema-1 file retains all previously saved choices and imports only
these newly supported fields from the read-only Swift fallback. Loading does
not rewrite it; the next explicit durable choice atomically stores schema 2.
Unsupported versions and malformed existing data are retained and reported.

The added fallback keys are `liveWindowSeconds`, `translateTailSeconds`,
`livePreviewEnabled`, `aiReconcileEnabled`, `debugCapture`, `vadConfThreshold`
and `captionSettings.v1`. This brings the queried setup/presentation/session
keys to seventeen; workspace preferences remain separately owned.

Swift's `as? Double` / `as? Bool` restoration is distinct from AppStorage's
Foundation getter conversions. Both are preserved. Caption JSON uses the
original strict synthesized decoding: absent required fields or wrong types
fall back to the complete default object. Optional screen/language fields stay
optional. Loading does not clamp captions; size/panel controls clamp all four
numeric dimensions, while optional screen/language changes do not clamp them.

Multiple targets floor response speed at 7 seconds, except a two-language pair
containing Korean. The stored 5-second preference remains 5; the effective value
is derived. Restore does not clamp other valid finite legacy values merely
because their controls have narrower ranges. Nonfinite values fail validation.

| Control family | Implemented boundary | Remaining product connection |
|---|---|---|
| Input/source/diarization/overlap | Connected Settings controls; distinct transient intents; file ASR admission uses current token/OSD | Live capture and disabled-while-recording behavior |
| Display language/appearance | Connected segmented controls and cross-window events; Settings follows system appearance as in Swift | Full native appearance/interaction comparison |
| Response speed/preview | Connected controls, exact restore and effective-window policy | Live capture/preview consumer |
| Translation targets/tail/AI correction | Connected controls, model availability and four-target intent | Translation and correction consumers |
| Caption sizes/patient options | Connected controls, monitor inventory, strict decode and original clamp/optional bindings | Native caption panels and complete multi-monitor checks |
| Debug capture/VAD threshold | Connected controls and fixed native debug-folder action | Session diagnostic bundles and review presentation |
| Auto-save/folder/export | Connected Settings controls and localized native folder panel; existing archive/export owner | Complete native interaction and persistence matrix |
| Glossary/model management | Connected Settings rows/actions; native ordered integer-safe glossary projection and model owner | Actual transfer/cancel UI sequence, populated glossary UI and full native comparison |

## Settings-window integration

One hidden configured window is shown with the native Settings menu / Cmd+,
and the main-window Settings intent. Closing hides it; reopening retains the
selected tab. The Settings capability permits only its explicit shared stores
and fixed native destinations, with no arbitrary renderer file path, file
admission, transcript edit or export authority. Settings setup intents are
limited to audio source and diarization; its workspace intent is auto-save.

Listeners subscribe before snapshots load, and monotonic revisions prevent a
late snapshot from overwriting a newer event. Device/screen inventory refreshes
on focus; entering Translation refreshes the model owner. Native SF artwork and
ko/en/ja strings come from the original sources. The initial 33 pt height and
accessible-name differences were corrected and checked in the rebuilt app.

Local integration checks pass 97 Rust tests (12/71/14), four frontend contract/
queue tests, clippy, frontend/debug app build and strict relocated packaging.
The 95.38 MiB candidate also produces 22 native Metal words and five exports
from a relocated bundle. Actual UI changes were restored: Korean language,
auto-save on and glossary off with minimum two. A fresh process retains those
values. Model re-download was not clicked against the installed user model;
loopback owner tests provide separate transfer/cancellation evidence. See
`../evidence/macos-settings-ui-2026-11-04.json` for exact capture and binary hashes.

The follow-up replaces macOS web tabs with an AppKit `NSToolbar` using the
preference window style and original SF Symbols. A main-thread-only owner retains
the delegate, toolbar and window, releases them on app exit and updates labels
only from current preference revisions. No AppKit object is made Send/Sync.
The renderer subscribes before installation and keeps its tab listener alive
during language changes. Selection is explicitly updated for accessibility
actions, which did not receive the mouse path's automatic selection update in
the first candidate. The Windows harness retains its web tabs/native select.

Actual macOS checks verify all five native tab callbacks, title/content changes,
selection highlight, close/reopen, English and Japanese toolbar labels, Korean
restoration, and opening/canceling the input-source popup. Original and candidate
captures are both 984×1000 pixels at 2× (492×500 pt). AppKit font measurement
confirms body/headline 13 pt and caption 10 pt; the form now uses those sizes,
native picker artwork, separate button/note rows and the bottom content inset.
This is **not full pixel parity**: button-row spacing, slash-containing text
wrapping, finer control metrics, themes and complete interaction coverage remain
open. The 95.72 MiB candidate passes the native/package checks in
`../evidence/macos-settings-toolbar-2026-11-04.json`.

The preceding Settings integration `50ce8a4` passes desktop CI `41767977083`
with 97 macOS / 89 Windows Rust tests, four frontend tests, all references and
both builds. Downloaded binaries and package/runtime/notices match clean source
provenance (`../evidence/desktop-ci-50ce8a4-2026-11-04.json`). That CI run predates
the native-toolbar follow-up.

## Verification

- Live extracted Swift initializers/AppStorage getters and pure properties match
  native Foundation and portable Rust in 725 cases: 5,075 font-step snapshots,
  105 caption blobs, 725 caption clamp snapshots and 725 effective-window states.
  Floating-point bits are retained across the reference JSON, including signed
  zero in fonts and caption fields. Fixtures are volatile; original user
  preferences are neither loaded nor written by this test.
- Local Rust tests: 87 (11 core / 62 platform / 14 protocol). New real-file tests
  verify schema migration, transient settings across unrelated writes, failure
  rollback and subsequent explicit start-screen persistence. Existing ownership,
  cancellation, shutdown and native-file authority tests remain green.
- ASR launch configuration matches 601 existing Swift cases after moving OSD
  ownership into setup. A relocated native probe uses overlap disabled and
  produces 22 JFK words, then passes archive/workspace and all five exports.
  Original source/model data and temporary cleanup are preserved.
- Debug app, frontend, formatting, clippy and strict relocated package pass with
  16 direct notices. These do not certify Settings UI or actual app relaunch.
- Two frontend queue regressions check that file admission waits for pending
  preference commits and that a failed commit cancels queued and later actions.
  The previous error-swallowing queue fails the latter regression; the shared
  setup queue now retains its failed state while allowing picker cleanup.

The prior preference revision `ec5b8d2` passed macOS CI but failed Windows clippy
on a macOS-only event import; `eb6b2e4` fixes the import. Its Windows build checks
then passed but the reference gate failed at the source-reference assertion: path keys used Windows separators and newly
hashed source files lacked explicit LF attributes. `e3096ad` uses POSIX keys and committed LF source attributes. An
isolated checkout with `core.autocrlf=true` / `core.eol=crlf` verifies all eight
reference source hashes. Revision `e3096ad` subsequently passes actual macOS 15
and Windows Server 2022 CI with 84/76 Rust tests, original 432-case preference
references and both debug builds. Downloaded executables, the macOS package,
inner runtime and sixteen notices match their hashes; build trees/diffs are
clean. This verifies the earlier setup/presentation revision, not these expanded
settings contracts. CI artifact receipts retain the failed attempts as well.
Local
settings-contract proof is in `../evidence/macos-settings-contract-2026-11-04.json`.

The form follow-up gives toggle and button rows their own spacing and permits
line breaks after path separators without changing the source string. Actual
Save-tab comparison now aligns the folder row/diagnostics section and the
`Madi/` diagnostic-path line break. Fine button/control metrics and the complete
visual matrix still remain open. Frontend build, four frontend tests, debug app
and strict packaging pass; see `../evidence/macos-settings-form-2026-11-04.json`.
