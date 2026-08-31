---
name: madi-release
description: Build, verify, and publish Madi macOS DMG releases with the repository release CLI. Use when a user wants a release plan, local DMG build, immutable S3 upload, S3 channel/index publish, or the legacy GitHub-release promotion flow.
---

# Madi Release

Use this skill only for Madi macOS release work. The single source of truth is `apps/macos/scripts/madi_release.sh`.

Do not reimplement release logic, mutate S3 directly, or hand-edit `index.json`. Drive every release action through the CLI and report the JSON result.

## Workflow

1. Run the plan step first.

   ```bash
   apps/macos/scripts/madi_release.sh plan <version> --json
   ```

2. Read the JSON plan before doing anything else. Confirm:
   - command
   - version and channel
   - releaseRoot
   - bucket and prefix
   - latestUrl and indexUrl
   - whether AWS or GitHub auth is required
   - `signing.mode` — `developer-id` (sign + notarize + staple) or `adhoc`.
     Report the mode to the user BEFORE publishing; when it is `adhoc`, quote
     `signing.reason` so they know what credential is missing. For a real
     user-facing release prefer `--require-notarized` once credentials exist
     (`MADI_SIGNING` and credential setup: docs/RELEASE.md §2).

3. Choose exactly one CLI action:
   - `build` — local DMG build or reuse only
   - `upload` — local build or reuse, then immutable S3 upload only
   - `publish` — local build or reuse, immutable S3 upload, then channel/index publish
   - `promote-github` — legacy GitHub Release asset promotion; use only when explicitly requested

4. After any non-plan action, read the JSON manifest and report:
   - artifact path
   - artifact URL
   - SHA-256
   - latest URL
   - index URL
   - whether publish actually occurred

## Command Rules

- For a read-only preview, stop after `plan`.
- If the user asks to build but does not explicitly ask to publish, run:

  ```bash
  apps/macos/scripts/madi_release.sh build <version> --json
  ```

- For immutable artifact upload without changing feeds, run:

  ```bash
  apps/macos/scripts/madi_release.sh upload <version> --json
  ```

- For the normal S3 release flow, only an explicit publish request authorizes:

  ```bash
  apps/macos/scripts/madi_release.sh publish <version> --json
  ```

- For the legacy GitHub Release path, only run this when the user explicitly asks for GitHub promotion:

  ```bash
  apps/macos/scripts/madi_release.sh promote-github <version> --json
  ```

- Never run raw `aws s3`, `aws cloudfront`, or manual `jq` edits against release metadata when this skill applies.
- Never edit `releases/index.json` by hand.
- Never use `--skip-tests` unless the user explicitly requests it.
- Use `--offline` only when the user explicitly wants the offline DMG included.

## Output Contract

- Keep command logs separate from the JSON result.
- If the CLI returns JSON, cite concrete fields instead of paraphrasing from memory.
- Let the CLI preflight AWS or GitHub credentials before a mutating command. If preflight fails, stop and report that prerequisite.
- If the CLI fails, report the failing subcommand and the exact blocker.

## Examples

- Plan only:

  ```bash
  apps/macos/scripts/madi_release.sh plan 0.1.0 --json
  ```

- Local build only:

  ```bash
  apps/macos/scripts/madi_release.sh build 0.1.0 --json
  ```

- Publish to S3 feed:

  ```bash
  apps/macos/scripts/madi_release.sh publish 0.1.0 --json
  ```
