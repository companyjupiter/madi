# Native macOS title policy

`madi-core::title` ports the unchanged shipping `TitleGenerator.swift` prompt
and title sanitization. The native macOS adapter supplies Foundation's own
alphanumeric classifier, preserving the installed OS's Unicode categories.
No model, file, setting, or archive is changed by this policy.

The order remains first nonempty line, optional title label, Markdown removal,
whitespace collapse, illegal path-character removal, punctuation trimming,
second whitespace collapse, and a 24-grapheme cap. Canonically equivalent
Korean labels are recognized without normalizing the returned title. Swift
splits extended grapheme clusters, including its treatment of CRLF; the Rust
port deliberately retains that behavior.

Run `python3 scripts/check_title_parity.py` on macOS. It compares both the title
and the complete prompt against a separately compiled, unchanged Swift source.
The 4,029 deterministic cases include Korean/NFD, Latin, CJK, combining marks,
emoji sequences, Unicode whitespace, wrapping, illegal filename characters,
length boundaries and randomized combinations. The script honors Cargo's
configured target directory. Its source-hashed report is retained in
`out/title-parity/report.json` and uploaded by macOS Desktop CI.

Two core regressions cover path/wrapping behavior and extended-grapheme limits.
Changing the cap from 24 to 23 deliberately fails the grapheme regression;
the original source was restored and its hash rechecked.
The macOS comparison has zero differences. This is a policy gate, not an
end-to-end AI title feature: post-session DNA requests, final summary/title
presentation, generation-safe rename and settings migration remain unconnected.
The existing timestamp fallback continues to use Foundation in the archive
adapter. Windows native title integration remains deferred.
