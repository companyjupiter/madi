# Native translation client

`madi-core::translation::client::Client` owns the shipping `TranslateEngine`
state transitions. `madi-platform::translation_client::TranslationClient` executes
its requests through the session's shared `DnaBroker`. It does not create a
second broker, expose engine/model paths to JavaScript, or publish directly into
the transcript. The session owner must route broker events to this adapter and
other clients, and validate source revisions before accepting results.

The client retains per-language prefix registration and previous committed
source/translation pairs. It preserves priority-language ordering, the interim
reservation, queue-cap and secondary-language shedding, displaced-request
callbacks, queue versus distinct-line counts, and caption pressure. Forced
prefixes apply only to eligible interim requests and negotiated `fp` capability.
The same capability gates `%%MAX`; repair retries have no cached prefix, forced
prefix or example pair. A stale retry cannot replace a newer pending revision.

Partial callbacks use the original strict greater-than-80-ms throttle, including
updating its clock before echo/script/runaway gates. Final results use the same
output policy, retry once on objective failure and report terminal empty results
so barriers drain. Runaways never become examples; interim results never become
committed context. Source LF replacement retains the shipping handling of CRLF.

## Ownership and recovery

Each native request maps its broker ID to one client ticket. Partial replies also
require the current process generation. Timeout suspends pumping immediately;
the next READY clears prefix/capability caches before pending requests resume.
Failed prefix registration falls back to a full prompt for that language.

Attachment returns its process generation atomically. Old buffered Started,
Stopped and Unavailable events cannot erase a replacement client's queue. When
there will be no subsequent READY (normal exit, failed relaunch or exhausted
restart budget), the broker emits Unavailable for the stopped generation. The
client drains both submitted and client-owned work, closes admission, and requires
a new client for an explicit restart. This is a transport-lifetime guard; it does
not change successful translation output or queue ordering.

A caption lease clears caption pressure and detaches on drop. Explicit stop awaits
the final detach's reaping acknowledgement; other attached clients can keep the
shared process alive. The attachment response itself holds cleanup ownership
until received: cancellation after the response was queued cannot leave a hidden
resident client. The ordinary broker attach API disarms that response guard only
when returning its ClientId to the caller.

## Verification

- `scripts/check_translation_client_parity.py` compiles unchanged TranslateEngine,
  turn/output and shedding sources, with an extracted unchanged interval function.
  Deterministic broker callbacks and clocks make 165 sequences / 6,767 operations
  comparable. Source CRLF remains in inputs; callback replies follow the actual
  parser's LF-flattening contract. Requests, callback order, prompts, depth,
  acceptance and runaway counts match. This is a client-state comparison, not a
  comparison of the two process supervisors.
- Ten real child-process tests cover shared residency, cached context, forced
  prefixes, stale retries, suppression, runaway isolation, failed prefixes, NUL
  rejection, timeout cache/capability reset, exhausted recovery, crash draining,
  old-generation events, pressure release and cancelled attachment ownership.
- Cancellation after a queued attach reply was reproduced as a failing test and
  passes after the ownership fix. Two intentional mutations (stale retry
  replacement and old-generation stop acceptance) are detected and restored.
- `translation_client_smoke ENGINE MODEL` runs public text through real Metal
  DNA4B: two committed translations, one forced interim translation and another
  client's request. One process serves both clients and is reaped. Full model and
  engine hashes agree before and after the probe.

CI runs live Swift comparison on macOS and the same pinned source/input/result
hashes on Windows. See `../evidence/macos-translation-client-2026-11-05.json` for
local results and the earlier policy-only CI receipt
`../evidence/desktop-ci-138a741-2026-11-05.json` for that separate revision.

## Remaining product work

Connect the client to file/live model admission and stable-line/coalesced
translation scheduling, then source-revision acceptance, interim display
agreement, tail timers and stop-time backfill. The renderer, transcript/archive
and preview busy/aging decisions still need those session effects. Successful
CLI probes do not establish UI/UX parity, model quality, document-corpus import
or Windows GPU acceptance. The shipping app remains the comparison baseline.
