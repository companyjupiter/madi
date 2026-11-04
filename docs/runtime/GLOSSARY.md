# Personal glossary migration

`madi-core::glossary` ports the original `GlossaryStore.swift` value and mutation
rules. It is not yet connected to the desktop preference owner, Settings tab,
edit learning, engine prompt or automatic transcript correction.

The original defaults remain disabled with two confirmations required. Loading
a pre-v2 blob raises the minimum to at least two while preserving entries;
v2 or later blobs clamp the minimum to one. Missing and null fields use the
original decode defaults. A malformed blob fails decoding so the caller can
use the original complete-default fallback policy.

Learning ignores empty/self corrections and increments an existing rule even
when its replacement changes. The latest replacement wins. Canonically
equivalent Unicode dictionary keys share the same rule while retaining the
first key spelling. The master switch controls application, not learning or
the active-rule list. Clear/forget do not reset the switch or threshold.

Active rules sort by their wrong token; Settings rows sort by hit count then
wrong token. The actual Settings computed property is extracted into the
native comparison harness, and the unchanged Swift store is compiled directly.

Validation covers 254 decode/mutation cases and 4,799 states, including
malformed fields, old schemas, zero/negative counts, Unicode equivalence,
retargeting, disabled learning, removals and numeric boundaries. Swift's
integer-literal and floating-point decode paths differ at Int64 limits; the
Rust adapter preserves that distinction without rounding an overflowing
integer into range. The live and pinned portable gates pass. One Rust regression
checks an intentional failure policy: learning into a legacy Int64.max count
returns an error without changing its replacement/count, whereas Swift traps.

Next integration order:

1. Port `PersonalVocabulary` normalization, particle handling, edit diff,
   confidence/matching rules, display-only corrections and Korean prompt caps.
   Compare unchanged Swift, including grapheme counts and source-word identity.
2. Add an isolated atomic owner with read-only `personalGlossary` fallback;
   connect Settings mutations and successful file edits to the same owner.
3. Apply corrections at the same ingest/finalize boundaries and take prompt
   terms at native file admission. Preserve user-edited text and translations.
4. Connect the original Settings rows and verify native appearance/interactions.

Reference: `design/parity/glossary-reference.json`. Local evidence:
`docs/evidence/macos-glossary-value-2026-11-04.json`. No real user glossary has
been read, changed or imported by this comparison.
