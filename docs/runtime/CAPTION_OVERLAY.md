# Caption overlay candidate

The transcript toolbar now toggles a staff caption window when translation
targets exist. The native owner projects the newest translated line and actual
audio tail from the same file/live snapshots used by the transcript. Patient
enablement, screen, language and sizing come from the shared settings owner.
Removing all translation targets or closing the staff overlay hides both
windows. Caption windows receive caption text, speaker display, meter, settings
and artwork; they cannot request file paths, edit transcripts or change models.

Disabling the patient panel while the overlay is shown now releases its native
window, matching the original controller. Turning the whole overlay off keeps
both instances hidden. Re-enabling the patient panel during asynchronous native
destruction waits for Tauri's `Destroyed` event before creating a new instance.
The panel converts back to its original Tauri native class before destruction.
Each created window gets a fresh generation in its local URL and projection;
snapshot/close and native-thread resize checks reject requests from a retired
instance. Re-creation is queued off the native callback thread, after Tauri's
old-label and listener cleanup. No sleep or retry loop drives this lifecycle.

The original `CaptionOverlay.swift` source remains unchanged. The Rust policy
preserves selected empty translations, authoritative/interim pairing, stale
speaker age, patient language precedence and viewer-localized status. Interim
translation remains disabled by the product's existing feature decision; live
ASR preview is shown while authoritative translation is unavailable. The host
stores at most two transcript lines. Revision guards prevent late file callbacks
or a stale toggle snapshot from restoring old content or disabled targets.

macOS uses `tauri-nspanel` 2.1.1 to create nonactivating, non-key, borderless
NSPanels at status-bar level, with all-Spaces/fullscreen-auxiliary behavior,
transparent background, no native shadow and background dragging. Initial
width, screen selection and bottom-center offset follow the original controller.
Native SF Symbol images come from AppKit. React measures content height and
fits translation text within the configured two/three-line limits. Windows uses
unfocused, nonfocusable, topmost Tauri windows; its behavior still needs device
validation. The additional dependency's MIT notice ships with the debug app.

`scripts/check_caption_parity.py` compares 1,500 cases with the original
CaptionView computed bodies, patient-language computation, CaptionStatus and
SpeakerID helpers. It uses an explicit JSON fixture scaffold, not an actual
SessionController or native window. It pins source and result hashes for Windows
reference comparison. Multi-value fallback without a matching language is
excluded: Swift Dictionary iteration does not define a stable winner; the Rust
map currently chooses its first sorted value. This edge remains a parity gap.

Eight desktop host tests cover bounded/full-history equivalence, stale revisions,
target disable/re-enable, selected empty translation, absent interim producer,
viewer separation, window identity and stopping automatic reopening after panel
failure. IPC contract tests constrain the caption
capabilities. Deliberate pairing and age mutations must fail the Swift comparison.
Lifecycle tests additionally cover rapid disable/re-enable, whole-overlay hiding,
unexpected destruction and late requests from retired windows. Both deliberate
retired-instance acceptance and premature label-reuse mutations are detected.

The caption source is also bootstrapped from the common file snapshot endpoint,
so restored/idle snapshots do not depend on a macOS-only workflow callback. The
first caption CI (`cd0526f`) passed 147 Windows Rust tests but failed strict
clippy because that callback was the only production reference. The shared
bootstrap corrects that dependency. Both push and PR CI at `d1e5032` now
report successful macOS 15 and Windows 2022 jobs.
The same run passed 174 Mac Rust tests and the 1,500-case native Swift caption
comparison, then failed because the old artwork oracle only listed 13 symbols.
That exact failure was reproduced locally; the oracle now compares all 18
original configurations, including the two toolbar states and three overlay
symbols, preserving dimension, PNG alpha and pixel-size checks. The expanded
oracle passes locally. This is native metadata/artwork validation, not a rendered
SwiftUI/WebView screen comparison.
When AppKit artwork is unavailable, the toolbar uses the same provisional SVG
caption motif as the overlay instead of an empty, zero-width button. This does
not establish Windows icon parity with the original SF Symbol.

Native visual/UX acceptance is **NOT_RUN** while the Mac is locked. Exact text
wrapping/minimum scaling, native content-height behavior, focus retention,
dragging, Spaces/fullscreen, screen hot-plug and patient enable/disable need
comparison in the original and candidate apps. Actual native release/recreate
and stale IPC behavior also require that check. Windows artwork, multi-monitor
DPI and taskbar/focus behavior are also
unaccepted. Build/oracle success does not establish identical UI/UX or release
readiness.
