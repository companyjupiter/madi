# Personal glossary migration

`madi-core::glossary` ports the original `GlossaryStore.swift` value and mutation
rules. `personal_vocabulary` adds its original edit diff, matching and prompt
policy. A shared native owner now connects isolated persistence, file edits,
incoming-word correction, final display correction and file-engine prompt terms.
**The Settings tab UI is not connected or visually verified.** Stable-line
correction timing during translation and the combined Korean number-formatting
pass remain incomplete.

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

## Matching and native ownership

The matcher follows grapheme counts, canonical equality, Swift lowercasing,
allowlisted Korean particles, the 0.8 confidence floor and the exact-key-first
policy. Non-exact Jaro–Winkler matching requires five-character tokens and a
0.92 score. Same-position edit substitutions learn only when token counts match;
the actual source permits a short replacement even though its leading comment
suggests otherwise. Whitespace graphemes follow Swift's leading-scalar predicate.

Prompt terms remain opt-in, confirmed, Hangul-script-only, strongest first,
deduplicated and bounded to 32 terms / 900 characters. Original edge behavior is
preserved: length eligibility precedes trimming, and the interior-space check
tests ASCII space specifically. The live comparison covers 193 cases, 5,390
queries and 4,063 edit/similarity pairs, with exact floating-point score bits.
One case has equal-hit, canonically equivalent right-hand spellings. Six fresh
Swift processes produce both NFC and decomposed prompt strings for that tie.
Only those ambiguous terms are compared canonically, and the actual bytes must
be a source spelling. All other outputs remain exact. This is not a claim of
byte-identical prompt selection for an ordering the original does not define.

The native owner reads only `personalGlossary` from the original preference
domain and never writes it. Its new `glossary.json` lives in the isolated app
configuration directory. Loading does not write. Accepted learning/settings
commands serialize on an owned thread, atomically replace the file and publish
only after saving. Canceled replies do not cancel accepted writes. File workers
finish their edits before glossary shutdown is joined. Invalid isolated data is
retained and reported; a malformed legacy blob follows Swift's default fallback.

Successful word and line edits teach the same owner even while application is
disabled; stale generations and unsuccessful edits do not learn. File admission
waits for previously queued glossary writes before taking prompt terms. Incoming
corrections happen before word construction; final corrections use an edit
overlay and preserve words, timestamps and identities. Even a same-text manual
line edit is protected from the final automatic pass, as in Swift. A failed
glossary save preserves the last durable rules and does not discard the successful
transcript edit; it reports a diagnostic. That disk-failure policy is explicit,
since Swift's UserDefaults save exposes no equivalent synchronous error result.

Remaining integration order:

1. Port the combined Korean number-formatting pass and stable-line timing,
   including translation-target, tail and held-word gates. Connect translation
   consumers before claiming full live/file correction behavior.
2. Connect the original Settings rows and verify native appearance/interactions.
3. Verify real-user glossary import/relaunch, live capture and full UI acceptance.

Reference: `design/parity/glossary-reference.json`. Local evidence:
`docs/evidence/macos-glossary-value-2026-11-04.json`. No real user glossary has
been read, changed or imported by this comparison.

The value-only revision `8ddd3c3` passed desktop CI `41752275613` with 88 macOS /
80 Windows Rust tests. Both clean executables and the macOS package/runtime/
sixteen notices match their hashes. Its glossary JSON was omitted from the
upload manifest; the receipt retains the exact verified report from CI logs.
The upload list now includes glossary and personal-vocabulary reports.

The connected candidate passes 92 local Rust tests (12 core / 66 platform /
14 protocol), including real child-process checks for disabled learning,
word/line edits, stale-generation rejection, prompt environment, incoming and
late display correction, manual same-text protection, identity and archive
preservation. Native Foundation volatile fixtures match all 254 storage cases,
including malformed data and a non-Data property-list value.

The 94.78 MiB debug app passes strict package relocation with 16 direct notices.
Using its actual relocated decoder/Metal ASR, a synthetic glossary survives
owner restart and supplies the admitted prompt; the JFK clip produces 22 words.
Editing an actual native transcript word is durably learned by that same owner.
Five exports, source/model/archive preservation and temporary cleanup pass.
This remains headless native-owner evidence, with UI and real-user acceptance
open. See `docs/evidence/macos-vocabulary-integration-2026-11-04.json`.
