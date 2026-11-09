# GTK GLib iterator backport

The GTK3 dependency graph required by the pinned Tauri stack selects `glib
0.18.5` on Linux. The macOS arm64 and Windows x64 graphs do not select it.
GitHub reports this release under
[GHSA-wrw7-89jp-8q8g](https://github.com/advisories/GHSA-wrw7-89jp-8q8g): its
string iterator passes an immutable pointer reference to a variadic C out
parameter. Optimized Rust can discard that write and then dereference null.

GTK3's 0.18 requirements cannot select the advisory's fixed 0.20 series. The
workspace therefore selects a local backport with `[patch.crates-io]`. The
version remains honestly identified as 0.18.5. All 121 files of the published
crate are retained, including its MIT license. The only changed file is
`src/variant_iter.rs`: `let p` becomes `let mut p` and the out argument becomes
`&mut p`. These are exactly the two changes in the upstream
[fix b5a4071](https://github.com/gtk-rs/gtk-rs-core/commit/b5a4071e439bef2b5eea76c3aa25e5ae84839e34).
The original patch is retained under `patches/` with its authorship.

`scripts/check_glib_backport.py` verifies the registry archive's Cargo checksum,
the official patch hash, every retained file and the exact two-line delta. It
also rejects a lockfile that still selects the registry copy. Byte-preserving
Git attributes keep this audit independent of Windows checkout line endings.
Neither an advisory allow-list nor a severity threshold change is used.

The dependency-review job additionally compiles an optimized, thin-LTO probe
against the untouched release in a temporary directory, and then against the
selected backport. Both must compile. Forward, reverse and alternating string
iteration must crash on the untouched version and return the expected empty,
ASCII, Korean, combining-mark and emoji strings on the backport. Core dumps are
disabled and the repository's vendor files are never mutated. Compiler failures
are not accepted as evidence of the runtime defect. The resulting report and
build logs are uploaded even on failure.

```sh
python3 scripts/check_glib_backport.py
# Linux with libglib2.0-dev, pkg-config and the repository Rust toolchain:
python3 scripts/check_glib_backport.py --exercise-regression
```

This tests the actual GLib FFI with release optimization; it does not claim
Linux product or GTK/WebKit UI acceptance. Replace this temporary backport when
the GTK dependency chain can select an upstream fixed release, and update the
audit and regression together. See `../evidence/glib-backport-2026-11-09.json`
for local provenance checks; Linux runtime/CI results are separate evidence.
