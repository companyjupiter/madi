# Transcript text passes

`madi-core::korean_numbers` ports `KoreanNumberFormatter.swift`, including its
ordered Sino-hard, Sino-soft and native-number passes. The counter allowlists,
single `이` exception, preceding Hangul/ASCII-digit boundary, verb-ending guard
and single-syllable time continuation rule remain unchanged. For example,
`천구백사십년` becomes `1940년`, while `오시면`, `이 시기` and `1만 년` stay intact.
Parsing compares Swift Characters canonically; the regex itself does not
normalize the input. Checked integer arithmetic preserves an out-of-range
input instead of Swift's overflow trap.

The regex adapter checks the preceding scalar itself because Rust regex has
no lookbehind. A rejected start advances by one scalar, not the entire match:
otherwise `가삼 일월` would incorrectly hide the valid `일월` suffix. Once a
start passes the boundary, matches remain nonoverlapping even when another
guard subsequently rejects conversion, as with Foundation.

`text_passes::TextPasses` applies glossary display correction and number
formatting in one pass. This lets the number formatter see a glossary output
such as `삼십분` and display `30분`. It writes the existing line edit overlay,
leaving original word text, confidence, timestamps and identities intact.
Explicit manual line edits, including successful same-text edits, protect the
row. Word edits keep the original behavior: glossary display correction skips
their edited overlay, but number formatting may still apply.

The stable scan preserves the source's conditions:

- No translation targets means no in-progress text pass.
- Normal word/segment boundaries exclude the last row and visit at most 32
  stable rows. A held-ending row and later rows wait while preview is nonempty.
- The cache records post-pass text. A changed glossary alone does not reprocess
  unchanged stable text. Finalization bypasses this cache and sweeps all rows,
  including the tail, regardless of translation targets.
- Reset clears manual protection and the cache. The platform worker consults
  the shared preference owner at each relevant event, so target changes during
  file processing are observed without copying the admission configuration.

The live Swift comparison uses the original formatter and store, plus the
unchanged combined-pass body and pre-translation scan extracted from
`SessionController.swift`. It compares 5,839 number inputs and 137 event/edit
sequences with 4,679 snapshots. Fixtures cover the 32-row boundary, changing
targets/rules, manual edits, original word identity, held-word preview release,
canonical spellings, repeated passes and reset. Both gates also run against
pinned source/corpus/result hashes on Windows.

Native child-process tests verify target changes during processing, delayed
tail formatting, late glossary-to-number composition, manual same-text
protection, saved Markdown and source-word preservation. Final display delivery
still follows the original 33 ms render timer; phase completion is not a claim
that every display overlay has already been published.

Translation generation, its tail timer/dispatch, live preview capture and full
native UI parity remain open. These text-pass gates do not certify those paths.
The actual macOS startup check also exposed missing preference/settings/glossary
command declarations in Tauri's permission manifest. The declarations and
main-window grants are now paired with a regression check across the native
registry, generated permissions, capability and renderer calls. A build alone
had not detected that startup failure.
