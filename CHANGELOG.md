# Changelog

Madi uses Semantic Versioning for public releases. Downloadable binaries live on
the `stable` release channel; retired binaries remain represented by permanent
source tags and release notes. See [docs/RELEASE.md](docs/RELEASE.md) for the full
release and provenance policy.

## [0.4.1] — 2026-09-20

- Clarified that the Madi application source is AGPL-3.0-only.
- Shipped the AGPL license and complete third-party notices inside the app.
- Documented the separately licensed redistributable translation-engine binaries.
- Added DNA3.0-2B and Sparkle attribution.
- Corrected the exported summary-deck product name.
- Kept the transcription and translation engine binaries identical to 0.4.0.

## [0.4.0] — 2026-09-16

- Improved non-English speaker-turn continuity and weak-label handling.
- Added PreviewTrim so interim text begins after committed text.
- Eliminated Korean file-mode chunk dropouts in the measured corpus.
- Fixed edited-row cascades and stream-stop finalization.
- Added language-correction and Korean number-formatting guards.
- Bounded translation runaway/retry behavior and video-import memory.

## Earlier releases

The complete highlights for `0.1.0` through `0.3.21`, including publication dates,
exact source commits, and retained artifact checksum prefixes, are maintained in
[README.md](README.md#version-history) and
[docs/RELEASE.md](docs/RELEASE.md#retention-binaries-may-retire-provenance-does-not).

[0.4.1]: https://github.com/companyjupiter/madi/releases/tag/v0.4.1
[0.4.0]: https://github.com/companyjupiter/madi/releases/tag/v0.4.0
