# UI/UX reference inventory

Baseline source: `c1390c750f2506e556a277421e146d80195ab797` (Madi 0.4.1 source).
Native dark Korean first-run/setup captures now exist, with provenance in
`../../docs/evidence/macos-native-baseline-2026-11-04.json`. They are comparison
evidence, not an approved full golden matrix. Do not call the browser candidate a
golden image, and do not update expected images to make a diff pass.

`theme-reference.json` resolves the unmodified shipping Theme.swift with AppKit
in aqua/darkAqua. It contains the OS and source checksum. The generated CSS uses
explicit theme selectors. `asset-reference.json` records unchanged copied art.

`translate-reference.json` and `transcribe-reference.json` pin protocol corpus,
source and output hashes obtained from the unmodified Swift implementation on
macOS 27.2. These are behavior references, not visual baselines. macOS 15's
Foundation BOM preservation differs from 27.2; live native comparisons record
the selected compatibility policy while a separate canonical hash check keeps
the cross-platform default fixed. Do not regenerate either reference merely
because a test fails.

| Reference area | Source | Required capture/action states | Status |
|---|---|---|---|
| Model gate | ModelGateView.swift, FirstRunModelSetupPolicy.swift | New install; required-only/recommended; download/check/cancel/error/retry; existing models | Native first-run/recommended download captured; other states pending |
| Start | ContentView.swift `setToStartCard` | ko/en/ja, light/dark; 1150×710 and 980×640 outer frame on the observed Mac; resizing | Dark Korean native comparison corrected frame and spacing; parity open |
| Setup selections | `languageRow`, `meetingChips`, `speakerBlock`, `micPicker` | Language self-exclusion; max 3 outputs; no translation; mode preset then override; system/mic/both | Rust rules tested; native Korean/Lecture IPC verified; full UX pending |
| File staging | `setupDropZone`, `setupCTA` | First valid dropped file; Unicode/truncated name; bytes/k/M; remove; mutual exclusion of start buttons | Pending |
| Session controls | `sidePanel`, `bigControlButton`; SessionCoordinator | Countdown, preparing, recording, pause/resume, stop confirm, tail/flush, timeout/EOF/recovery | Pending |
| Transcript | TranscriptView.swift, TranscriptFollowModel.swift | Content/detailed/conditional chat; partial/final; speaker fix/overlap; translations; find/edit/cancel/copy/scroll anchor | Pending |
| Workspace | WorkspaceExplorer.swift | Hidden during recording; tree expand/order/open/rename; autosave/toast/failure; export | Pending |
| AI | summarySheet, PrepBriefView, RecapCardView, LiveSummaryPane | Summary/Q&A, cancellation, stale replies, calendar-triggered prep and dismissal | Pending |
| Caption | CaptionOverlay.swift, ClinicDisplaySupport.swift | Nonactivating overlay, staff/patient screen, fullscreen/multi-monitor/DPI | Pending |
| Settings/help | SettingsView, InfoView, UpdateView, offline manual | All reachable tabs, live language/appearance, model lifecycle, stable/beta/rc update failure/recovery | Pending |

Fixed initial capture metadata must include source commit, binary SHA-256,
bundle variant, model readiness, preferences, OS/build, monitor scale, content
size, theme, UI language and fixture ID. A clean-install reference and an
existing-user reference are separate. No production preferences are changed by
the current Tauri harness.

The Swift source requests `min(1150, visibleWidth - 60)` by
`min(710, visibleHeight - 60)` and converts with `frameRect(forContentRect:)`.
Its SwiftUI window actually captures at 1150×710 **outer** points on this Mac.
Tauri Transparent initially produced 1150×743; the macOS host now measures native
chrome and subtracts it from the requested inner height. Setup minimum is
980×640 in the same observed frame convention; the work minimum is 760×520 in
the source and still needs its own native measurement.
Staging a file does not leave setup. Idle plus no display lines defines setup.

Preserve existing disabled defaults: dictation, voiceprints, editor analytics,
interim translation and translation streaming. Live summary has a separate
experimental persisted opt-in. Their existence in source is not evidence that
the default product exposes them.

## Open visual/interaction gaps

- The Mac is unlocked and Xcode/Metal setup is complete. Strict-asset native
  baseline and packaged Tauri debug builds pass. Dark Korean setup has been
  compared and its outer frame/major spacing corrected; remaining native
  titlebar appearance, font widths and other screen/state coverage are open.
- CSS `ui-rounded`/system font stacks and the current chevron/check glyphs have
  not proven identical to SwiftUI or licensed equivalents on Windows.
- The ready-model start fixture has no real device enumeration or model gate.
- Popup positioning, keyboard focus, IME, file staging and transition behavior
  still need native-oracle scenarios. No generic screenshot tolerance is approved.
- Windows titlebar/buttons, system dialogs and platform wording remain open;
  the fixture intentionally retains the current Mac wording for comparison.

Every item stays open until there is a measured pass or a user-approved change
to the requirement. Browser rendering alone never closes G0/G2.

## Structured events and process ordering

`structured-reference.json` pins 2,945 `EngineEvents.swift` inputs, including
1,707 actual checked-in transcript fixture lines. Duplicate-key selection is an
explicit compatibility option; the live oracle probes its runtime while an
independent canonical hash check protects the shared default. Very large
arbitrary-precision Foundation numeric coercions are outside the bounded engine
contract and remain unsupported; this is not a complete Foundation replacement.

`stream-reference.json` records 20 actual child-process comparisons against
unmodified `EngineProcess.swift`. Only the disabled debug logger is stubbed.
The fake child writes real stdout and EVENTS_FILE bytes, uses stdin acknowledgments
to order partial writes, and exits with buffered tail output. Rust must deliver
complete JSONL records before the associated stdout barrier and termination
after the last stdout event. Incomplete JSONL without a later barrier stays
uncommitted, matching the source. This does not validate a real inference engine
or replace production lifecycle/cancellation tests.
