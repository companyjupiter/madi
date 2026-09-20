# Prebuilt translate engines

`translate-engine-4b` and `translate-engine-2b` are the on-device LLM runners the
app bundles as `Contents/MacOS/translate-engine-{4b,2b}` (live translation,
summaries, Q&A, titles). They are small self-contained arm64 executables
(macOS 14.0+, system frameworks only, Metal library embedded) that load a
DNA3.0 GGUF the app downloads on demand. The models themselves are **not** here.

**Source is not in this repository, and these two files are not covered by Madi's
AGPL-3.0 license.** They are separate programs that the app launches as child
processes and talks to over pipes. The engines are built from the author's
private `sovereignLLM` project and are distributed here as binaries only. Anyone —
individuals and companies alike — may use them free of charge and redistribute them
unmodified under the [Madi Translate Engine Binary License](LICENSE.md). Everything
else in Madi builds from source.

| file | runs | checked by |
|---|---|---|
| `translate-engine-4b` | DNA3.0-4B i1-Q4_K_M (16 GB+ Macs) | `SHA256SUMS` |
| `translate-engine-2b` | DNA3.0-2B i1-Q4_K_M (8 GB Macs) | `SHA256SUMS` |
| `MANIFEST.json` | provenance: sha256, size, LC_UUID, build time, the sovereignLLM commit that last touched each engine | — |

`apps/macos/scripts/make_app.sh` bundles these by default and refuses a file whose
SHA-256 does not match `SHA256SUMS`. It also copies [`LICENSE.md`](LICENSE.md) into the
app as `Contents/Resources/TRANSLATE_ENGINE_LICENSE.md`, because that license permits
redistribution only when its text travels with the binaries. `TRANSLATE_ENGINE_4B` / `TRANSLATE_ENGINE_2B`
point it at other binaries (a fresh engine build, a CI download); those are not
checked against this folder.

Maintainers refresh the folder after rebuilding the engines:

```sh
apps/macos/scripts/update_translate_engines.sh [path-to-sovereignLLM]   # default ../sovereignLLM
git add engine/prebuilt && git commit
```

The script copies the two binaries, requires arm64 + the app's minimum macOS +
system-only linkage, and rewrites `SHA256SUMS` and `MANIFEST.json`. The builds
committed on 2026-09-19 are the ones shipped in Madi 0.4.0 (same LC_UUID).
