# Privacy

Madi is designed so meeting audio and derived content are processed on the Mac.
There is no account, advertising SDK, analytics SDK, or telemetry endpoint in the
application. This document describes the current public build; changes that add a
new network destination or a new category of stored data must update this file.

## What stays on the Mac

- Microphone and system audio are passed to the bundled transcription engine.
  System-audio capture uses macOS ScreenCaptureKit, but Madi discards video frames
  and does not save screen images.
- Transcripts, translations, summaries, Q&A, speaker labels, glossary entries,
  preferences, and optional voiceprints are computed and stored locally.
- Finished transcripts are auto-saved by default under `~/Documents/madi/`, or in
  a folder the user selects. The user can disable auto-save and delete these files
  with Finder.
- Models, voiceprints, translation caches, and app state live under
  `~/Library/Application Support/Madi/` (one legacy translation cache uses the
  sibling `Sovereign/` directory). Preferences use macOS `UserDefaults`.
- Short WAV segments are temporary working files. They are removed by the normal
  session cleanup path. A crash can leave temporary files until macOS or the user
  clears the temporary directory.

Madi does not upload these items. When a user deliberately shares an exported
file or diagnostic bundle, the destination chosen by that user controls it.

## Network connections

Madi connects to the network only for software and model delivery:

- the speech model and optional translation model are downloaded from the URLs
  declared in `AssetManifest.swift`; downloaded files are verified by SHA-256;
- update metadata and appcast files are read from `madi.devart.tv`; and
- Sparkle downloads an update selected by the user and verifies its EdDSA
  signature. The legacy updater also verifies byte size and SHA-256.

Normal transcription, diarization, translation, summaries, and transcript Q&A do
not call a cloud inference service.

As with any direct download, the hosting provider and ordinary network
infrastructure can observe request metadata such as IP address, time, and the
requested file. Madi does not add user identifiers or transcript content to those
requests.

## Permissions

- **Microphone:** captures microphone audio when the user starts a session.
- **Screen Recording / System Audio:** captures audio playing on the Mac. Video
  frames are discarded.
- **Calendar:** the codebase contains a local, read-only meeting-context bridge.
  It is disabled in the current public flow; if enabled in a future build, macOS
  will ask first and the data remains local.

macOS permissions can be revoked in System Settings at any time.

## Diagnostics

Diagnostic capture is off by default. If the user enables it, Madi writes a
session bundle under `~/Library/Application Support/Madi/debug/`. It can contain
audio segments, transcript text, translation turns, engine input/output, file
paths, process metrics, and configuration details. Treat it as sensitive: inspect
and redact it before sharing, and never attach it to a public issue.

## Deleting data

Delete exported transcripts from the selected save folder. Delete downloaded
models, debug bundles, voiceprints, and local caches by removing
`~/Library/Application Support/Madi/` (and the legacy
`~/Library/Application Support/Sovereign/` cache if present) while Madi is not
running. App preferences can be cleared with:

```sh
defaults delete com.companyjupiter.madi
```

Uninstalling the app alone does not delete user documents or Application Support
data.

## Recording consent

The person operating Madi is responsible for obtaining any consent required to
record or transcribe other people and for complying with applicable workplace and
local law.

Report a privacy or security issue through GitHub private vulnerability reporting
as described in [SECURITY.md](SECURITY.md).
