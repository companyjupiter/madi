# Native media staging

The macOS parity host now opens `NSOpenPanel` on AppKit's main thread with the
same four UTTypes, single selection and directory exclusion as
`ContentView.chooseStagedFile`. It retains AppKit's default modal presentation
and labels. It does not substitute a web upload control or an extension filter.
The objc2 bindings are documented at
https://docs.rs/objc2-app-kit/0.3.2/objc2_app_kit/struct.NSOpenPanel.html.

The async command dispatches the modal work to the main thread without holding
the setup mutex. A duplicate invocation does not open another panel. Cancellation
leaves the old selection intact. Native drop delivery selects the first accepted
path in original order, including replacement of an existing selection. The
UTType policy intentionally matches the original, including unknown/no-extension
behavior; registration differs by OS. Staging is not a codec-support guarantee.

`SetupHost` retains the original path. Web IPC cannot submit arbitrary paths;
`SetupState` exposes only filename and formatted size. Clearing selection drops
that reference without deleting or decoding the source. The setup snapshot's
revision orders drop notifications and command replies. The frontend subscribes
before reading its initial snapshot and removes subscriptions on unmount.
Only host event listening/unlistening and the no-path picker command were added
to the main local window's capability; filesystem/shell/remote grants remain absent.

The staged card uses the original content/close SVGs, name/size typography,
shadow and spacing. Its name and device labels use middle truncation over whole
graphemes. Start-file and recording CTA availability follows the original staged
selection rule. Their actions still emit harness intents; inference/session UI
is not connected. Windows native selection/drop policy is explicitly unsupported.

`scripts/check_media_file_parity.py` extracts `isMediaFile` and `fileSizeLabel`
verbatim from the shipping `ContentView.swift`, compiles a headless Swift oracle,
and compares 39 synthetic filesystem cases with Rust. Cases include audio/video,
non-media, unknown/uppercase/missing extensions, Korean/emoji names, missing
files, a directory, a symlink, byte-unit boundaries and decimal rounding ties.
The first comparison caught decomposed Hangul returned by Foundation file URLs;
the native Rust adapter now uses the same URL bridge for display names. The
corrected local comparison passes without normalizing either oracle's output.

Actual picker selection/cancellation, OS drop delivery, staged-card geometry,
middle truncation and keyboard behavior still require CUA comparison after the
Mac is unlocked. Automated policy checks do not close those native UI gates.
