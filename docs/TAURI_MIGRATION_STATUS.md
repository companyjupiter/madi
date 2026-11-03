# Tauri migration status

Updated 2026-11-04. **Migration is active, not complete.** macOS and Windows are
the initial targets. The source baseline is Madi `c1390c7` / 0.4.1.

| Gate | Current evidence | Still required |
|---|---|---|
| G0 baseline | Source/state inventory; 28 actual AppKit color tokens in light/dark; original artwork hashes; existing Swift tests pass | Native screenshot and action baseline, deployment-version match, fonts/SF Symbols and Windows exceptions |
| G1 feasibility | Rust parser differential; macOS Tauri host builds and starts; fixed-model Windows LLM runners pass Windows CPU/PTX CI | Native IPC/UI interaction, Windows Tauri build CI, Windows ASR, GPU/model inference, audio/caption/calendar feasibility |
| G2 UI | Initial start-screen candidate, ko/en/ja static text, two themes, setup commands owned by Rust | Native visual/UX comparison, real devices/models, file staging, model gate, transcript/settings/workspace/AI/overlays |
| G3 macOS core | Translation stream parser, initial setup rules | Session lifecycle, stdout/JSONL merge, storage/migration, audio capture, engine supervisor, AI policy and real end-to-end |
| G4 Windows | SovereignLLM experimental PE executables exist | GPU numerical/quality/performance, ASR, WASAPI, decoding, full product integration and Windows 11 device validation |
| G5 release | Experimental host is isolated and release builds are disabled | Licensing/package audit, signing, installer/update migration, rollback and all earlier gates |

## Measured checks

- `cd apps/macos && swift test`: 718 tests, **2 skipped**, 0 failures on this Mac.
  The two capture-fragmentation tests need `MADI_EVENTS_JSONL` and
  `MADI_CAPTURE_STDOUT`; they are not counted as capture/inference validation.
- `cargo test -p madi-core -p madi-protocol`: 7 unit tests pass.
- `python3 scripts/check_translate_parser_parity.py`: **5,082** chunked input
  cases match the unmodified shipping Swift parser, in translation and summary
  modes. Unicode, malformed bytes, markers, forced-prefix/capability lines and
  empty turns are included. The corpus caught a leading BOM decoding difference,
  which was corrected. Event-stream SHA-256:
  `8c6f39fb05bf1701bd090fb244a42cfca7ba4ed112d9a8bf1b3083e9ae128d39`.
- `cargo clippy --workspace --all-targets -- -D warnings`: passed with the explicit capability manifest. CI on the committed revision
  must confirm the other platform.
- `cd apps/desktop && npm run build`: TypeScript and Vite build pass.
- `cargo build --locked -p madi-desktop --features custom-protocol`: macOS
  standalone debug host builds. `npm run tauri dev -- --no-watch` also starts the
  native process. A process start is not a UI interaction pass.
- Browser-only setup fixture was viewed at 1150×710 in light/dark. Local images:
  `out/desktop-parity/setup-{light,dark}-browser.jpg`. These are candidate renders,
  not the native golden images. Browser fixture selection does not emulate IPC.

The host currently assumes a ready-model setup fixture and holds choices in
memory. File/start buttons emit a harness intent only. No recording, model
download, inference, file writing, data migration or updater is connected yet.

## SovereignLLM Windows engine

Implementation and private source remain in the separate SovereignLLM repo:
[draft PR #257](https://github.com/companyjupiter/sovereignLLM/pull/257).
The `DNA3.0-2B Q4_K_M` and `DNA3.0-4B Q4_K_M` forks each build one fixed-model
Windows x64 executable, with the current Madi protocol.

[Windows run 41686183745](https://github.com/companyjupiter/sovereignLLM/actions/runs/41686183745)
passed on engine commit `15a21711affa884a0b710d87f2effa06eed838ec`:
14 CPU unit tests, two invalid-startup process checks, both PE builds,
62 PTX partition/bounds contracts and six NVIDIA ptxas assemblies. Downloaded
PE sizes/hashes match the CI report; the engine repository records their
provenance in `docs/evidence/windows-dna3-2026-11-04.json`.

This establishes a Windows Server 2022 CPU build/test result. It does **not**
establish GPU inference, full-model tokenizer parity, numerical/translation/
summary quality, latency, VRAM usage, Windows 11 UI or concurrent ASR. No Windows
runner has been copied into Madi's release prebuilt directory.

## Environment dependencies and next work

1. Native UI capture is waiting for the Mac to be unlocked. The computer-use
   tool reported a locked Mac; no native screenshot or click test was attempted
   past that boundary.
2. Full native baseline build failed because the Metal toolchain is absent.
   `xcodebuild -downloadComponent MetalToolchain` also found a missing
   CoreSimulator framework. `xcodebuild -runFirstLaunch` is waiting in
   `AuthorizationCopyRights` for administrator authentication. User input is
   pending; do not classify this as an application-code failure.
3. Windows NVIDIA hardware/runner details are pending. Continue CPU, protocol
   and product-core work while awaiting hardware; do not substitute compilation
   for the GPU gate.
4. Run the new macOS/Windows desktop workflow on the committed branch, then
   continue the original stdout/JSONL parser and session lifecycle ports with
   Swift differential fixtures.
5. Once the native environment is ready, capture the actual baseline and
   correct the initial screen against it before closing any UI gate.

The working feature branches are `codex/tauri-ui-parity` (Madi) and
`codex/windows-dna3-engines` (SovereignLLM). Shipping macOS UI, data and the default
release channel remain the comparison and rollback baseline.
