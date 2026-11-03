# First-run model entry policy

`madi_core::model_setup` ports the complete pure
`FirstRunModelSetupPolicy.swift` policy. It does not start a download, read a
filesystem path, persist a choice, or change the desktop screen yet.

| Required Whisper ready | Setup choice | Translation engine | DNA ready | Entry |
|---|---|---|---|---|
| No | Any | Any | Any | Blocked |
| Yes | None (existing installation) | Any | Any | Enter |
| Yes | Transcription only | Any | Any | Enter |
| Yes | Recommended | Absent | Any | Enter |
| Yes | Recommended | Present | No | Wait |
| Yes | Recommended | Present | Yes | Enter |

The choice remains optional: initializing it to Recommended would incorrectly
block existing installations that only have Whisper. Choosing transcription only
while DNA downloads changes entry eligibility; it does not cancel that download.
The native downloader will still own cancellation and verification state.

Download totals include Whisper only when missing, and the selected DNA2B/4B
asset only for Recommended when missing. As in Swift, engine availability does
not affect this pure total; `ModelGateView` hides the recommended download action
when its engine is absent. The Rust API takes the pinned model variant so callers
cannot supply an arbitrary or overflowing asset size.

`scripts/check_model_setup_parity.py` compiles both complete, unchanged shipping
Swift policy/manifest files. All 48 combinations of required readiness, optional
readiness, engine presence, three choices and two variants agree on entry and
download bytes. Pinned source/corpus/result hashes are checked in
`design/parity/model-setup-reference.json`. Windows uses `--rust-only` and does
not claim live Swift validation. `--write-reference` requires a successful live
comparison. The original five `FirstRunModelSetupPolicyTests` also pass locally.

Desktop integration must initialize native readiness before presenting the first
frame to preserve the original existing-install no-flash behavior. Beta expiry
remains a separate, earlier app gate. Download progress, retry/cancel races,
atomic verified publication, native UI fidelity and first-run network behavior
are not validated by this policy comparison.
