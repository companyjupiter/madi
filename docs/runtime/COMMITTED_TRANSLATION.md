# Committed session translation

The experimental Tauri macOS host supplies trusted engine/model locations to
`FileWorkflow`. A session uses one `DnaBroker` and lazily attaches its caption
client when a routed, missing translation needs a request. A selected target
matching the source language does not start another process. The shipping fast
model-size gate remains an admission check, not an integrity receipt.

The core committed scheduler preserves the original stable scan of 32 lines,
held-word deferral, script-based source-language routing, fragment coalescing,
220-grapheme limit, three-second gap, unsettled-speaker rule and source revision
gates. Coalesced replies carry the anchor's revision. Empty guarded responses
suppress that exact revision; obsolete responses cannot overwrite or suppress
an edited source. Committed partial streaming remains disabled as in Swift.

Words rearm the configured tail deadline. Stop finalizes text passes, disables
both shedding limits, backfills valid dropped language/revision keys and queues
remaining stable lines. Recording also retries valid dropped work on the
five-second idle tick. Each language closes only its own backfill key. Native
preference changes turn off the client even without another ASR event.

Reset and a replacement session detach/reap the old caption lease before the
next session can accept callbacks. Quit after ASR finalization waits for the
translation queue and archive checkpoint. The immediate ASR durability save is
retained, and a subsequent settled-translation save includes late replies in
the same owned archive. This extra checkpoint deliberately prevents the new
asynchronous owner from leaving its final translations only in memory. Opening
an existing archive does not claim it as a save target.

Live preview admission now observes the DNA busy signal, gives committed ASR
priority, and permits an aged preview at two seconds with queue depth <= 6 or
four seconds above that threshold. A one-second tick reevaluates a steady busy
lane. The last accepted preview, rather than a mere attempted submission,
advances the clock. Actual simultaneous microphone/ASR/DNA behavior remains an
acceptance item.

Validation includes unchanged Swift coalescer/routing comparisons (360 cases,
8,005 input rows), core revision/backfill regressions, seven child-process file
workflow tests, three deliberate mutations, and a real public-audio ASR/DNA4B
probe through this same workflow and archive owner. The probe's model inputs
and source audio are preserved. See
`../evidence/macos-committed-translation-2026-11-05.json`.

FAQ persistence, starter-pack lookup and committed cache reuse are now connected;
the terminal-client/shed-backfill regression is also covered. See
`TRANSLATION_CACHE.md` for that follow-up and its separate evidence.

This is not complete translation or UI/UX parity. Interim translation and
committed token streaming stay disabled, matching `LiveFeatureWiring.swift`.
Caption overlays, the full backlog HUD, summary/AI broker
consumers, complete live timing tests, visual comparison, Windows native
ASR/capture and Windows GPU inference remain open. The existing shipping Swift
implementation remains the comparison baseline.
