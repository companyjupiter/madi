# Model manifest and read-only integrity

The Rust port preserves `AssetManifest.swift`'s three pinned assets, download
URLs, byte counts, SHA-256 values and memory recommendations. This is a model
catalog/verification layer; the desktop first-run gate and installer are not
connected yet.

## Selection and lookup

`madi_core::assets::TranslationVariant` selects DNA2B below 12 GiB and DNA4B at or
above 12 GiB. `MADI_TRANSLATE_MODEL` values `2b`/`4b` override the recommendation,
case-insensitively without whitespace trimming. Native callers supply the
environment and physical memory; the core never reads global state.

`madi_platform::model_assets::Locations` receives native-owned bundle resource,
executable and existing Madi support roots. Existing bundled Whisper takes
precedence even if invalid, matching Swift. Translation models live in the
support root; engine lookup checks presence beside the host. Windows lookup adds
`.exe`, but no Windows model/runtime integration is established by this catalog.
Construction never creates the support directory, unlike the original Swift
`supportDir` accessor. This keeps migration discovery read-only.

The quick launch gate follows development seed symlinks and checks size only,
as the shipping app does. It does not prove integrity. Full hashing belongs at
download/install/reuse validation; doing it on every launch would change startup
behavior. Neither engine existence nor model size implies runnable inference.

## Integrity and ownership

`file_is_valid` rejects a final symlink/reparse point, non-regular file, missing
file, mismatched size or SHA-256, and I/O errors. It opens read-only without
following the final link, hashes in bounded 8 MiB chunks and uses the same open
file for size and digest checks. Unix nonblocking open prevents a raced-in FIFO
from waiting for a writer. Windows opens the reparse point itself and rejects its
attribute. Size/mtime are checked again after hashing. The low-level `sha256`
function follows links, matching the original standalone hash utility.

Verification writes or removes nothing. It proves the bytes just read, not that
a mutable path can never change after return. A future installer must own its
download temporary file and publish the verified file atomically; this helper
alone is not an installer or an immutable admission token.

## Evidence

`python3 scripts/check_asset_manifest_parity.py` compiles the complete, unchanged
shipping manifest with a small oracle. Three asset records, 70 deterministic
selection cases and 27 integrity cases match Rust exactly. Ten additional cases
exercise the original override property at the actual Mac memory size. Fixtures
include same-size corruption, truncation, uppercase digest mismatch, symlink,
missing/directory paths, Unicode and an 8 MiB buffer boundary. Originals remain
unchanged. Rust regressions additionally cover special files and read-only lookup.

`design/parity/asset-manifest-reference.json` pins source, corpus and result
hashes. Windows runs `--rust-only` against that reference and explicitly reports
no live Swift execution. Reference replacement requires the explicit
`--write-reference` option and a successful live macOS comparison. Symlink
creation failures fail the check rather than silently skipping coverage.

The local installed-model receipt
[`macos-model-integrity-2026-11-04.json`](../evidence/macos-model-integrity-2026-11-04.json)
records full Rust verification of the existing Whisper Q8 and DNA4B files, with
unchanged sizes, modification times and identities. DNA2B is absent, not counted
as verified. The probe used the release-optimized `asset_manifest_oracle` CLI,
feeding the pinned asset byte counts and hashes with `hashInput: false` (full
verification already hashes the file once). It performed no download or model
write. Native first-run UI, damaged-download recovery and installer publication
remain separate work.
