# Settings command and persistence boundary

The original Settings scene contains Recording, Save, conditional Translation,
Glossary and Model tabs. Its 460×380 content frame plus SwiftUI padding is the
layout baseline. This change ports the session-setting contract and file-engine
admission needed by that scene. **The Settings window and its controls are not
connected yet.** No native settings-window, live-capture or caption-overlay UI
acceptance is claimed.

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
| Input/source/diarization/overlap | Shared setup and distinct Settings intents; file ASR admission uses current token/OSD | Settings controls, live capture and disabled-while-recording behavior |
| Display language/appearance | Existing presentation owner and main-window application | Settings segmented controls; the original Settings scene itself has no preferredColorScheme override |
| Response speed/preview | Exact restore, commands and effective-window policy | Live capture/preview consumer and Settings UI |
| Translation targets/tail/AI correction | Four-target intent, exact persistence and tail/reconcile state | Translation and correction consumers, model availability UI |
| Caption sizes/patient options | Strict decode, original clamp/optional-binding behavior | Native caption panels, monitor enumeration and Settings UI |
| Debug capture/VAD threshold | Exact AppStorage restore and command validation | Session diagnostic bundles, review presentation and Settings UI |
| Auto-save/folder/export | Existing workspace owner and file archive/export effects | Settings-specific folder panel text and bindings |
| Glossary/model management | Existing source inventory; first-run model service is available | Glossary learning/matching/persistence and settings-specific download/reveal actions |

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
