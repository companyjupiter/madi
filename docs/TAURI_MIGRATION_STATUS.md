# Tauri migration status

Updated 2026-11-04. **Migration is active, not complete.** macOS and Windows are
the initial targets. The source baseline is Madi `c1390c7` / 0.4.1.

| Gate | Current evidence | Still required |
|---|---|---|
| G0 baseline | Source/state inventory; 28 actual AppKit color tokens in light/dark; original artwork hashes; existing Swift tests pass | Native screenshot and action baseline, deployment-version match, fonts/SF Symbols and Windows exceptions |
| G1 feasibility | Rust parser differential; macOS Tauri host builds and starts; Windows Tauri debug host builds in CI; fixed-model Windows LLM runners pass Windows CPU/PTX CI | Native IPC/UI interaction, Windows ASR, GPU/model inference, audio/caption/calendar feasibility |
| G2 UI | Initial start-screen candidate, ko/en/ja static text, two themes, setup commands owned by Rust | Native visual/UX comparison, real devices/models, file staging, model gate, transcript/settings/workspace/AI/overlays |
| G3 macOS core | Translation/stdout/JSONL parsers, ordered stdout/JSONL barriers and EOF drain, deterministic session lifecycle, initial setup rules | Production lifecycle executor, storage/migration, audio capture, engine supervisor, AI policy and real end-to-end |
| G4 Windows | SovereignLLM experimental PE executables exist | GPU numerical/quality/performance, ASR, WASAPI, decoding, full product integration and Windows 11 device validation |
| G5 release | Experimental host is isolated and release builds are disabled | Licensing/package audit, signing, installer/update migration, rollback and all earlier gates |

## Measured checks

- `cd apps/macos && swift test`: 718 tests, **2 skipped**, 0 failures on this Mac.
  The two capture-fragmentation tests need `MADI_EVENTS_JSONL` and
  `MADI_CAPTURE_STDOUT`; they are not counted as capture/inference validation.
- `cargo test -p madi-core -p madi-protocol`: 24 unit tests pass.
- `python3 scripts/check_translate_parser_parity.py`: **5,082** chunked input
  cases match the unmodified shipping Swift parser, in translation and summary
  modes. Unicode, malformed bytes, markers, forced-prefix/capability lines and
  empty turns are included. The corpus caught a leading BOM decoding difference,
  which was corrected. Event-stream SHA-256:
  `8c6f39fb05bf1701bd090fb244a42cfca7ba4ed112d9a8bf1b3083e9ae128d39`.
- `python3 scripts/check_transcribe_parser_parity.py`: **2,728 scenarios /
  10,424 events** match unmodified `EngineProtocol.swift`. Includes preview
  quarantine, both language lock versions, progress, speaker corrections,
  Unicode/grapheme boundaries and Swift-compatible hexadecimal/NaN parsing.
- `python3 scripts/check_structured_parser_parity.py`: **2,945** inputs match
  unmodified `EngineEvents.swift`, including **1,707** checked-in real transcript
  fixture lines, missing/wrong-type fields, defaults, Unicode, unknown events,
  trailing commas and duplicate keys. Arbitrary-precision `NSNumber` coercions
  outside the finite bounded engine contract are explicitly not reproduced.
- `python3 scripts/check_stream_process_parity.py`: **20** real-child-process
  scenarios match unmodified Swift `EngineProcess` delivery exactly: stdout
  fragmentation, UTF-8 splits, partial JSONL retained across barriers, JSONL
  before segment/flush callbacks, preview isolation and 1,000-segment immediate
  exit with an unterminated tail. The child is a fixture, not an inference
  engine; product process supervision is still pending.
- Session lifecycle: seven Rust regressions preserve the existing Swift tests'
  tail-before-FLUSH ordering, exactly-once finish, generation/engine identity,
  cancelled imports, startup/flush deadlines, countdown and elapsed time.
  [Effect executor contract](runtime/SESSION_PORT_CONTRACT.md) records the
  asynchronous capture-stop acknowledgment and owned-temp-file requirements.
  No filesystem deletion, microphone or process executor is connected yet;
  live Swift/Rust lifecycle comparison remains open.
- `cargo clippy --workspace --all-targets -- -D warnings`: passed with the explicit capability manifest. CI on the committed revision
  must confirm the other platform.
- `cd apps/desktop && npm run build`: TypeScript and Vite build pass.
- `cargo build --locked -p madi-desktop --features custom-protocol`: macOS
  standalone debug host builds. `npm run tauri dev -- --no-watch` also starts the
  native process. A process start is not a UI interaction pass.
- Browser-only setup fixture was viewed at 1150×710 in light/dark. Local images:
  `out/desktop-parity/setup-{light,dark}-browser.jpg`. These are candidate renders,
  not the native golden images. Browser fixture selection does not emulate IPC.

## First CI result and compatibility correction

[Run 41690075166](https://github.com/companyjupiter/madi/actions/runs/41690075166)
at `957a537cb6eb5bc8f40ff198d0990f40ee32327f` is **overall failed**:
the Windows Server 2022 job passed unit tests, clippy and the standalone debug
Tauri executable build; macOS 15 passed those shared checks but failed the live
Swift translation-parser differential. This is not an all-platform green gate.

The failure exposed an OS/runtime difference: macOS 15 Foundation retains a
leading UTF-8 BOM, while the current macOS 27.2 reference consumes it. Rust now
has an explicit `Utf8BomPolicy`; the default remains the recorded 27.2 reference.
The live Swift comparison probes its actual runtime and selects the matching
compatibility policy. It never edits or filters the Swift events. A second,
independent check pins the canonical corpus and output hashes in
`design/parity/translate-reference.json` on **both** OSes, so the compatibility
check cannot silently change the cross-platform default. Any product selection
of the legacy policy and the supported native version baseline remain G0/G3
decisions; they are not silently inferred from the build host.

The stdout line corpus is also pinned in `transcribe-reference.json` and runs
on Windows without requiring Swift (`--rust-only`, explicitly reported as no
live Swift execution). The second run [41692423592](https://github.com/companyjupiter/madi/actions/runs/41692423592)
at `fe714b9` passed the translation comparison on macOS 15, then found a separate
stdout numeric syntax difference: its Swift runtime accepts uppercase `0X` and
symbolic `nan(foo)`, whereas Swift 6.4.2 on macOS 27.2 rejects them. The stdout
parser now exposes an explicit legacy float-syntax policy; its live comparison
probes that runtime and still checks the unchanged canonical default hash
independently.

[Run 41693205029](https://github.com/companyjupiter/madi/actions/runs/41693205029)
at `810ee299a4a28ec3f4d6e24c327382a44afc312d` passed **both macOS 15 and Windows
Server 2022**: formatting, 13 then-current Rust tests, clippy, frontend build,
translation/stdout reference checks and standalone debug Tauri builds. Windows
reported generated permission files changed during the build; provenance now
includes paths, and the next revision fixes their checkout line endings and
retains the exact build diff. Do not describe that historical tree as clean.
The new structured/stream checks are locally green; their next-revision CI is
pending. No UI, audio or inference gate is closed by these build results.

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
4. Verify the structured/stream checks on both CI hosts, then continue the
   session lifecycle and production process supervision ports with real-process
   fixtures and Swift comparison.
5. Once the native environment is ready, capture the actual baseline and
   correct the initial screen against it before closing any UI gate.

Madi work is in [draft PR #49](https://github.com/companyjupiter/madi/pull/49).
The working feature branches are `codex/tauri-ui-parity` (Madi) and
`codex/windows-dna3-engines` (SovereignLLM). Shipping macOS UI, data and the default
release channel remain the comparison and rollback baseline.
