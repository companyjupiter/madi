# Translation scheduling and output policy

`madi-core::translation` ports the shipping `TranslationTurnQueue`,
`TranslatePrompt`, `TranslationOutputPolicy`, `TranslationShedPolicy` and
`InterimTuning.adaptiveGuarantee`. This layer is pure policy; it does not launch
the DNA broker or publish translations into the desktop transcript.

Committed captions evict disposable interim requests and run newest-first.
One reserved interim survives that eviction and takes precedence so a committed
backlog cannot indefinitely starve the visible caption. A newer pending request
replaces the same line/language, while a retry cannot replace a newer revision.
Queue-cap shedding returns the oldest requests for later backfill; displacement
and shedding remain separate results. Under committed backlog, secondary targets
are shed only when the configured priority target is present.

The prompt body preserves the previous committed source/translation example and
the original fallback anchor. Empty, oversized, multiline and same-line revision
examples are rejected using Swift-compatible canonical equality and grapheme
counts. The guarantee interval is unchanged at backlog 0–2, doubled at 3–6 and
disabled above 6, or when the base interval is not positive.

Output cleanup removes leaked prompt labels, standalone arrows, thinking frames
and runs of at least three identical sentences. It preserves deliberate two-sentence
repetition and arrows inside words. Example-prefix stripping and near-replay
checks preserve legitimate retranslations of the same source. Retry decisions
still depend on raw versus cleaned emptiness, source repetition and observable
wrong-script output. Token caps, CJK-to-Latin expansion limits and sentence-end
truncation preserve the native bounds.

Text itself is not Unicode-normalized. Internal comparison keys use canonical
equivalence; default lowercase is noncontextual, like the Swift baseline. Searches
and replacements respect grapheme boundaries, including spaces or tag-ending
characters followed by combining marks. Foundation whitespace handling is retained.

## Evidence

Run `python3 scripts/check_translation_parity.py` on macOS. The oracle compiles the
complete unchanged `TranslationTurnQueue.swift` and `TranslationShedPolicy.swift`
plus the unchanged `adaptiveGuarantee` function extracted from
`TranslationStability.swift`. The diagnostic projection of private echo keys is
normalized to make Swift Character equality comparable; product strings are
compared without normalization. Similarity scores are compared as exact f64 bits.

The 3,574 cases comprise 1,839 output-policy cases, 1,366 prompt cases, 144 target
shedding/interval cases, 45 floating-point interval cases and 180 queue sequences
with 6,300 operations. Interval probes include NaN, infinities, signed zero,
overflow and subnormal values. Positive
replay, partial-echo and retry decisions are required, alongside rejection and
preservation cases. Cases include native regression examples, Unicode boundary
probes and deterministic generated sequences.

`--rust-only` checks the same input, source and result hashes against
`design/parity/translation-reference.json`. Windows CI uses this pinned mode;
macOS CI runs the live Swift comparison. Both retain report and result bytes.
Six intentional mutations (NaN interval admission, reservation admission, CJK
runaway bound, tag boundaries, near-replay threshold and arrow whitespace) are
detected before the original sources are restored. Local receipts are in
`../evidence/macos-translation-policy-2026-11-05.json`.

## Remaining acceptance

The client lifecycle, prefix-cache generation, broker ownership and 80 ms partial
throttling now have a native adapter and separate evidence in
`TRANSLATION_CLIENT.md`. Session revision acceptance, stable-line coalescing, tail
timers, interim display agreement and stop-time backfill still need connection
and tests.
No translation quality, full Unicode-universe equivalence, native UI/UX parity,
real-document application result or Windows GPU acceptance is claimed here.
