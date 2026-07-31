# Madi agent rules

## Quark V10 is mandatory for Madi diagnosis and implementation

Madi work must use Quark V10 whenever the task touches or evaluates reusable
capability, source topology, performance, memory, transcription, diarization,
live transcription, translation, DNA engines, Metal kernels, release quality, or
cross-project reuse. Treat Quark as a verification/contradiction tool, not as a
decorative report.

Canonical Quark directory:

```bash
cd /Users/jupitersong/antigravity/quark
```

Canonical Madi-related targets:

```text
configs/sovereign_whisper_app.mjs        # macOS Swift app completeness
configs/sovereign_metal_whisper.mjs      # Madi Whisper / diarization Metal+Zig engine
configs/sovereign_metal_dna3_2b.mjs      # DNA3 2B Metal engine
configs/sovereign_metal_dna3_4b.mjs      # DNA3 4B Metal engine
configs/sovereign_metal_dna3_9b.mjs      # DNA3 9B Metal engine
```

### Before design or code changes

1. Read the Quark history first when doing diagnosis or performance work:

   ```bash
   sed -n '1,220p' /Users/jupitersong/antigravity/quark/_history/INDEX.md
   ```

2. Run V10 asset discovery and context for the relevant target:

   ```bash
   ./q.sh asset find '<capability or suspected issue>' --target <target>
   ./q.sh context '<task>' --target <target> --budget 700
   ```

3. If Quark returns a relevant reusable asset or origin, inspect the READ_SET and
   run impact before changing it:

   ```bash
   ./q.sh asset impact <asset_id>
   ```

4. If Quark returns unrelated AWS/Redis/Teleport-style false positives, record
   that conclusion briefly and continue locally. Do not force adoption of an
   irrelevant asset.

### During implementation

- For Swift app changes, run:

  ```bash
  ./q.sh complete configs/sovereign_whisper_app.mjs
  ./q.sh gaps configs/sovereign_whisper_app.mjs
  ./q.sh asset bridge --target sovereign_whisper_app
  ```

  Invariant: `unwired` must stay `0` and app wiring must stay `100.0%`. New
  wired-but-untested files require an explicit reason or a test follow-up.

- For Whisper / diarization / transcription engine changes, run:

  ```bash
  ./q.sh regen configs/sovereign_metal_whisper.mjs
  ./q.sh asset bridge --target sovereign_metal_whisper
  ```

  Inspect `_mirror/by_perf_band/` and the exact atom directories for any claimed
  performance diagnosis. Do not optimize decoder kernels from contaminated
  profiling snapshots without a clean decode-only measurement.

- For DNA translation engine or low-memory policy work, run the relevant DNA
  target(s):

  ```bash
  ./q.sh regen configs/sovereign_metal_dna3_2b.mjs
  ./q.sh regen configs/sovereign_metal_dna3_4b.mjs
  ./q.sh regen configs/sovereign_metal_dna3_9b.mjs
  ./q.sh asset bridge --target sovereign_metal_dna3_2b
  ./q.sh asset bridge --target sovereign_metal_dna3_4b
  ./q.sh asset bridge --target sovereign_metal_dna3_9b
  ```

  If `_mirror/by_perf_band/` is empty, Quark has topology evidence but no current
  perf evidence. Add or run real measurements before calling a DNA optimization
  a win.

### Completion gate

Before committing or opening a PR for meaningful Madi changes:

1. Run:

   ```bash
   ./q.sh atlas status
   ./q.sh asset bridge --target <changed_target>
   ```

2. Ensure there is no Madi-relevant curated reverify backlog, bridge gap, or
   stale tree affecting the conclusion.
3. For `.zig`, `.metal`, `.m`, or performance-sensitive `.swift` changes, cite
   the Quark atom(s) used in the commit message or PR notes.
4. For performance or quality changes, commit only when there is an objective
   win or an explicit user-approved reason. Record meaningful measurements in
   `PERF_LOG.md` or the appropriate benchmark note.

### Promote reusable Madi wins

When a Madi implementation becomes a reusable verified capability, promote it
into Quark V10 instead of leaving it as tribal memory. Good candidates include:

- live diarization silence-birth guards
- live speaker correction / SPKFIX policies
- low-memory DNA model policy
- translation queue coalescing and committed-first scheduling
- permission preflight UX gates
- release-build reproducibility checks

Use `asset promote`, `asset adopt`, and `asset verify --run` where applicable.
Remember: `test_present` is not the same as pass evidence.
