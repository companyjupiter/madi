# Source and licensing provenance

This file records the boundaries that matter when distributing or contributing
to Madi. It is an engineering record, not legal advice.

## Current distribution boundary

- The Madi source tree at version 0.4.0 and later is offered under
  AGPL-3.0-only, subject to the notices in `NOTICE` and
  `THIRD_PARTY_LICENSES.md`.
- Revisions earlier than 0.4.0 remain in history for reference and are not
  retroactively offered under the repository license.
- `engine/prebuilt/translate-engine-{2b,4b}` are separate, source-unavailable
  executables under `engine/prebuilt/LICENSE.md`. They are not AGPL components.
- The downloadable model weights retain their upstream licenses. The app and the
  model/engine aggregate must not be described as wholly open source.
- The Madi name, logo, and app icon are not licensed by AGPL.

Use `MADI_BUNDLE_TRANSLATE_ENGINES=0 apps/macos/scripts/make_app.sh` to produce a
bundle containing the AGPL application and source-built transcription engine but
not the separately licensed translation-engine executables. The optional
translation, summary, Q&A, and AI-title features require those executables and
are unavailable in that bundle.

## Contributor record

`AUTHORS.md` identifies credited contributors. The maintainer must retain durable
evidence for every incoming contribution: the merged pull request, the CLA
checkbox/version accepted, authorship and third-party declarations, and any
employer authorization the contributor needs. A checkbox is useful workflow
evidence but is not a substitute for resolving a known ownership conflict.

Before accepting a contribution copied or adapted from another project, record
the upstream URL and revision, license, files changed, required attribution, and
compatibility analysis in the pull request and notices.

## Maintainer-originated history

Older commits include an `@lguplus.co.kr` author address. `.mailmap` normalizes
public attribution to the maintainer's personal identity; it does not rewrite
commit objects, transfer copyright, or establish employer authorization. The
maintainer should retain any applicable employment/IP carve-out outside the
repository before relying on dual licensing or proprietary distribution.

## Release provenance

- `VERSION` is the canonical marketing version; CI checks its mirrors in the app
  plist and Swift fallback.
- Release tags are permanent source provenance and must not be deleted when a
  binary is retired.
- S3 artifacts may be pruned under the documented retention policy, but the Git
  tag, GitHub release notes, checksums, commit, and publication date remain.
- A release manifest records the git SHA, dirty state, artifact hashes, and
  signing mode. See `docs/RELEASE.md`.

## Review checklist

Before each stable release:

1. run the version consistency, license-boundary, test, and bundle checks;
2. verify `NOTICE` and `THIRD_PARTY_LICENSES.md` against shipped files;
3. confirm contributor agreement and provenance evidence for new contributors;
4. create an annotated permanent tag on the manifest's exact commit; and
5. preserve release notes and checksums even if the binary later leaves the
   active download channel.
