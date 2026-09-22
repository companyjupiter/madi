# Security policy

## Supported versions
Only the current stable binary is supported. Older binaries can be removed from
the active download channel, while their release notes and source tags remain as
provenance ([docs/RELEASE.md](docs/RELEASE.md), Retention). Please update before
reporting (Help → Install Update…).

## Reporting a vulnerability
**Do not open a public issue.** Use GitHub's private reporting: the repository's
**Security** tab → **Report a vulnerability**. Include the Madi version, macOS
version, what an attacker can do, and steps to reproduce. You should get a first
answer within a week. Please give us reasonable time to ship a fix before
disclosing.

Useful to know when you assess impact:
- Madi processes audio on the device. The inference path makes no network requests;
  the app network surface is model and update delivery. See [PRIVACY.md](PRIVACY.md).
- Downloads are integrity-checked: the speech and translation models by pinned
  SHA-256, app updates by Sparkle's EdDSA signature and by the SHA-256 and byte
  size in the release feed.
- The app is distributed outside the Mac App Store and is not sandboxed. Current
  DMGs are ad-hoc signed, not notarized.
- Session debug bundles (Settings → diagnostic capture) contain transcripts and
  audio-derived data. Never attach one to a public issue.

## Verifying a download
Each release lists the DMG's SHA-256 (`SHA256SUMS.txt`, also in the GitHub Release
and in `https://madi.devart.tv/channels/stable/latest.json`):

```sh
shasum -a 256 madi-<version>-arm64.dmg
```
