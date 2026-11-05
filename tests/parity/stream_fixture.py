"""A child process with real stdout and EVENTS_FILE writes, never a model runner."""
import json
import os
from pathlib import Path
import sys

case = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
with open(os.environ['EVENTS_FILE'], 'wb', buffering=0) as events:
    for batch in case['batches']:
        events.write(bytes.fromhex(batch['json']))
        raw = bytes.fromhex(batch['stdout'])
        size = batch['chunk']
        for offset in range(0,len(raw),size):
            os.write(sys.stdout.fileno(), raw[offset:offset+size])
        if batch.get('ack'):
            if not sys.stdin.buffer.readline():
                raise SystemExit(91)
raise SystemExit(case['exit'])
