# Contributing to Madi

Thanks for wanting to help. Madi is a local-first macOS app: the whole inference
path runs on the user's Mac with no account, no API key and no cloud processing. Contributions that
keep it that way are welcome. 한국어로 이슈와 PR을 작성하셔도 됩니다.

## Before you start
- **Bugs and ideas:** open an issue with the templates. For anything larger than a
  small fix, open an issue first so the approach can be agreed before you write it.
- **Security problems:** do not open a public issue. See [SECURITY.md](SECURITY.md).
- **License:** Madi is AGPL-3.0-only. Every pull request also needs the
  [Contributor License Agreement](CLA.md) (one checkbox in the PR template),
  because the project plans paid features on top of the open code.

## Build and test
Requirements: an Apple Silicon Mac, macOS 14 or later, Xcode command-line tools
(`xcode-select --install`) and [Zig](https://ziglang.org) 0.14.x (`brew install zig`).

```sh
apps/macos/scripts/fetch_runtime_assets.sh   # once: seven small runtime assets, SHA-256 pinned
apps/macos/scripts/make_app.sh               # builds the engine if needed → apps/macos/build/Madi.app
MADI_BUNDLE_TRANSLATE_ENGINES=0 apps/macos/scripts/make_app.sh  # AGPL/source-only bundle
cd apps/macos && swift test                  # core test suite
apps/macos/scripts/tests/madi_release_test.sh   # release tooling tests (only if you touch scripts/)
```

The normal product bundle includes separately licensed prebuilt translate engines
from [`engine/prebuilt/`](engine/prebuilt/README.md). The source-only command above
omits them. The speech model (~830 MB) is downloaded by the app on first launch,
not by the build. See [`docs/PROVENANCE.md`](docs/PROVENANCE.md).

## What a good pull request looks like
- **One change, explained.** Say what was wrong or missing, what you changed, and
  how you checked it.
- **Measure what you claim.** Performance, accuracy, latency and memory changes are
  kept only with a measurement. Put the numbers in the PR; changes that land are
  recorded in `PERF_LOG.md` (app + engine rounds) or the matching bench note.
  A lever that did not help is worth recording too.
- **Tests.** Logic that can run without UI belongs in `SovereignCore` with a test
  under `apps/macos/Tests`. `make_app.sh` is the authoritative build: a new `.swift`
  file must be added to its source list or it will not be in the app.
- **No new cloud dependency** in the core path, and no telemetry.
- **User-visible text** goes through the KO/EN/JA localisation helpers. Manual
  sections live in `docs/manual/<lang>/`; rebuild with `node docs/manual/build_index.mjs`.
- **Third-party code or weights:** name the source and license in the PR and add the
  notice to `NOTICE` and `THIRD_PARTY_LICENSES.md`.

## Releases
Maintainers cut releases with `apps/macos/scripts/madi_release.sh`
([docs/RELEASE.md](docs/RELEASE.md)). Older binaries may leave the active download
channel, but release notes and source tags are permanent provenance.
