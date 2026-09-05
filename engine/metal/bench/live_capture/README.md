# live_capture — record the real app→engine stream and replay it byte-for-byte

Five offline reproduction attempts (same files/offsets, every env flag, preview
interleave, real-time pacing + concurrent 4B load, 80× accumulation) were all
clean while the live session was 29–53 % German. The only thing that reproduced
it was replaying the *captured live stream itself* — which is what these do.

1. Install the shim in the app bundle (ad-hoc signed, so helpers are not validated):
   ```
   A=/Applications/Madi.app/Contents/MacOS
   mv $A/transcribe $A/transcribe.real && cp tee_transcribe.py $A/ && printf '#!/bin/bash\nD="$(cd "$(dirname "$0")" && pwd)"\nexec /opt/homebrew/bin/python3 "$D/tee_transcribe.py" "$@"\n' > $A/transcribe && chmod +x $A/transcribe $A/tee_transcribe.py
   ```
   Restore: `mv $A/transcribe.real $A/transcribe && rm $A/tee_transcribe.py`.
2. Record a session. Capture lands in `~/Library/Application Support/Madi/engine-capture/<ts>/`
   (`env.txt`, `stdin.log` with timestamps, `wav/` snapshots at feed time, `stdout.log`).
3. Replay exactly: `python3 replay_capture.py <capture> [--engine out/transcribe_X] [--env K=V,...] [--paced]`
   — prints live vs replay German %, rescues, loop guard hits, and the differing lines.
   Bisect by flipping one env var at a time with `--env`.

2026-09-05: `--env PROMPT=` on a 93-segment English capture: 27 % German / 38 rescues → 0 / 0.
