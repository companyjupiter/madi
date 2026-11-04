# Translation cache integration

The experimental macOS host loads the shipping bank at Application Support /
`Sovereign/faq_translations.json`. Native code supplies this location; the webview
cannot choose a bank or engine path. A missing bank is seeded with the unchanged
15-entry Swift starter pack through a complete temporary file and no-clobber
publication. A concurrent creator wins. Unlike the original fallback writer,
malformed or unreadable existing files are retained and use an in-memory starter
bank. This deliberate change preserves user data during migration.

Single-line committed requests consult FAQ before the session interim LRU.
Normalization lowercases, removes Foundation whitespace, punctuation and symbols,
and requires four graphemes. Canonical-equivalent dictionary keys match Swift.
Later entries win. A partial FAQ hit queues only missing languages and does not
fall through to interim reuse. Coalesced runs bypass both caches. Engine/model
admission still precedes lookup, matching the shipping controller.

Each cached translation uses the source revision guard. Successful cache hits
close only the corresponding backfill keys, schedule a snapshot, and checkpoint
settled final-session translations in the owned archive. A terminal DNA client
cannot emit results for new rejected requests: these now use empty terminal
results to suppress their exact revision/language keys and close the barrier.
Previously, a real child-process crash left 14 shed backfill keys pending despite
a zero queue depth. The regression now closes them without inventing translations
or restarting the process in a loop.

The interim cache preserves the original 15-entry LRU, newline normalization,
canonical string equality, language merge, access ordering and session-boundary
clearing. Its committed lookup is connected. Interim request production and
caption display remain unconnected; this slice does not establish live-caption
translation parity.

On macOS, normalization uses the installed CoreFoundation punctuation/symbol
sets. The portable baseline is pinned to the measured macOS 27.2 Swift behavior;
104 symbols absent from Rust's category table are included explicitly. CI compares
native Rust with Swift on the same Mac and checks portable results against the
pinned reference on both platforms. Differences between older native Unicode
tables and the portable baseline are reported separately.

Evidence: `../evidence/macos-translation-cache-2026-11-05.json`. The cache oracle
covers 394 cases, every Unicode scalar, 7,200 LRU operations and the complete
starter pack. Core and real child-process tests cover backfill, partial cache
hits, zero model turns for a full hit, persistent-file preservation and concurrent
initialization. Three deliberate mutations are detected. A public JFK recording
passes through actual ASR, an isolated preset FAQ entry and archive saving in
about 1.5 seconds in the measured run. The preset text tests routing and storage,
not translation quality or DNA inference.

Remaining acceptance includes native GUI/live capture, the interim producer and
display, and Windows GPU/ASR. The comparison corpus excludes ambiguous entries
whose multiple language columns normalize to the same source: Swift Dictionary
iteration does not define a stable source-column winner. Empty cached values also
retain the shipping target-removal behavior; their interaction with stop backfill
needs an explicit follow-up. Neither edge is claimed as complete product parity.
