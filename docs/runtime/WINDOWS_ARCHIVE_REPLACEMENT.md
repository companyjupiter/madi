# Windows archive replacement investigation

The Windows job in Desktop run 41888398966 (6e90399) passed its initial workspace
tests, then failed the repeated concurrent archive checkpoint test. Its first
failure was checkpoint replacement with `Access is denied` (OS error 5). Other
threads later reported file-not-found: the test unwrapped a panicked worker
before joining the remaining workers, allowing its temporary directory to be
dropped underneath them. The harness now joins all workers before reporting a
panic so the original error is retained.

The pinned tempfile 3.27 Windows persist implementation normalizes attributes
and calls MoveFileExW. The pinned Rust 1.99.1 fs::rename additionally supports a
SetFileInformationByHandle fallback, including FileRenameInfoEx semantics on
supported Windows filesystems. See the official
[Rust rename documentation](https://doc.rust-lang.org/std/fs/fn.rename.html) and
[Microsoft file replacement documentation](https://learn.microsoft.com/en-us/windows/win32/fileio/moving-and-replacing-files).

The candidate checkpoint change clears the temporary attribute through `keep`,
immediately reinstates a cleanup guard, and uses fs::rename for the owned
destination. A failed replacement retains the old archive and removes the
temporary file. A successful replacement retires the temporary cleanup guard.
No deletion-before-write, copying fallback or timed retry is added. Initial
no-clobber allocation and macOS behavior remain unchanged.

A Windows-specific regression holds an ordinary shared file reader across the
replacement. It records the legacy tempfile result, requires the new path to
contain the new text and the existing reader to retain the old text, and checks
the stable owned path and absence of leftover temporary files. CI runs this
probe explicitly and retains the existing 50 concurrent repetitions.

At `885317f`, Windows CI records OS error 5 for the legacy shared-reader persist,
then passes the new replacement probe and all 50 concurrent repetitions. This
proves that the replacement handles a shared-open destination; it does not trace
the identity of the competing handle in the earlier intermittent failure. The
same job later fails the FAQ reference file hash because of Windows checkout
line endings, so the whole job is not green. See
`../evidence/windows-cache-checkout-2026-11-05.json`. The local Mac build does not
execute the Windows-only branch.
