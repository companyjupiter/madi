#!/usr/bin/env python3
"""Compare native workspace enumeration/calendar and stats to unchanged Swift."""
import datetime
import hashlib
import itertools
import json
import os
from pathlib import Path
import platform
import stat
import subprocess
import sys
import tempfile
sys.dont_write_bytecode=True
from check_model_gate_parity import block

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'out/workspace-parity'
BASE=ROOT/'apps/macos/Sovereign'
SOURCES=[BASE/p for p in ('Model/WorkspaceTree.swift','UI/WorkspaceExplorer.swift','Transcript/WorkspaceAnalytics.swift','Transcript/TranscriptStore.swift','Transcript/TranscriptArchive.swift','Transcript/SpeakerID.swift')]

def cases():
    result=[]
    for now,zone,(first,minimum) in itertools.product(
        ('2026-01-01T00:00:00','2026-03-08T07:00:00','2026-11-01T06:00:00','2026-11-04T02:00:00','2026-12-31T23:59:59','2011-12-30T12:00:00','1969-12-31T23:59:59'),
        ('UTC','Asia/Seoul','America/New_York','Pacific/Apia'),((1,1),(2,4))):
        timestamp=datetime.datetime.fromisoformat(now).replace(tzinfo=datetime.timezone.utc).timestamp()
        meetings=[]
        for index,offset in enumerate((0,1,-1,604799,604800,604801,-86400,-604800,-1209600,-3024000,-3628800,-60*60*23.5)):
            text=f'- **[00:00] Speaker {index%4}** first *low*\n- **[00:{index:02}] 미확인** next\n'
            if index==2:text='# unrecognized summary'
            if index==3:text='- **[00:00] Name** \n- **[00:00] Speaker 255** * *\n'
            meetings.append(dict(date=timestamp+offset,markdown=text))
        result.append(dict(now=timestamp,zone=zone,firstWeekday=first,minDays=minimum,meetings=meetings))
    result.append(dict(now=0,zone='UTC',firstWeekday=1,minDays=1,meetings=[]))
    return result

def main():
    if platform.system()!='Darwin':raise SystemExit('Native workspace comparison requires macOS; no simulated platform result')
    OUT.mkdir(parents=True,exist_ok=True)
    tree,view,_,store,_,_=[path.read_text(encoding='utf-8') for path in SOURCES]
    source='import Foundation\n'+store[store.index('struct Word:'):store.index('/// Stable, process-independent')]+block(store,'enum SegmentStatus: Equatable')+'\n'
    source+=block(tree,'struct FileNode:')+'\nenum WorkspaceScan {\n'+block(tree,'private nonisolated static func children(')+'\nstatic func run(_ root: URL) -> [FileNode] {children(of:root,depth:0,maxDepth:4,maxItems:2000)}\n}\n'
    source+='struct FixtureWorkspace {let nodes:[FileNode]}\nstruct FixtureSession {let workspace:FixtureWorkspace}\nstruct NativeRecent {let session:FixtureSession\n'+block(view,'private var recentTranscripts: [URL]')+'\nfunc read()->[URL] {recentTranscripts}\n}\n'
    extracted=OUT/'OriginalWorkspaceTypes.swift';extracted.write_text(source,encoding='utf-8')
    swift=OUT/'swift-workspace'
    subprocess.run(['swiftc','-parse-as-library',str(extracted),*[str(SOURCES[i]) for i in (2,4,5)],str(ROOT/'tests/parity/WorkspaceOracle.swift'),'-o',str(swift)],check=True)
    subprocess.run(['cargo','build','--locked','-p','madi-platform','--example','workspace_native_oracle'],cwd=ROOT,check=True)
    with tempfile.TemporaryDirectory(prefix='madi-workspace-parity-') as temporary:
        base=Path(temporary).resolve();tree=base/'tree';tree.mkdir();wide=base/'wide';wide.mkdir()
        names=['meeting 10.md','meeting 2.md','meeting 1.md','회의.md','회의 요약.md','회의 요약 2.MD','É.md','A.txt','.hidden.md','sub/meeting.md','sub/.hidden/deep.md','a/b/c/visible.md','a/b/c/d/too-deep.md']
        for index,name in enumerate(names):
            path=tree/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('- **[00:01] Speaker 0** words\n',encoding='utf-8');os.utime(path,(1700000000+index,1700000000+index))
        flagged=tree/'hidden-flag.md';flagged.write_text('hidden');os.chflags(flagged,stat.UF_HIDDEN)
        (tree/'alias.md').symlink_to(tree/'meeting 1.md');(tree/'loop').symlink_to(tree,target_is_directory=True)
        for index in range(2007):
            path=wide/f'item {index}.md';path.write_text('');os.utime(path,(1700000000,1700000000))
        payload=dict(roots=[str(tree),str(wide),str(base/'missing')],cases=cases());data=json.dumps(payload,ensure_ascii=False).encode()
        expected=json.loads(subprocess.check_output([str(swift)],input=data));rust=json.loads(subprocess.check_output([str(ROOT/'target/debug/examples/workspace_native_oracle')],input=data))
        if rust!=expected:
            (OUT/'mismatch.json').write_text(json.dumps(dict(swift=expected,rust=rust),ensure_ascii=False,indent=2),encoding='utf-8')
            raise SystemExit('Workspace mismatch; see out/workspace-parity/mismatch.json')
        def count(nodes):return sum(1+count(node['children'] or []) for node in nodes)
        assert len(rust['scans'][1]['nodes'])==2000
        report=dict(schemaVersion=1,status='passed',scanFixtures=3,scanNodes=sum(count(scan['nodes']) for scan in rust['scans']),calendarCases=len(payload['cases']),
            sources={str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in SOURCES},
            statsCorpusSHA256=hashlib.sha256(json.dumps(payload['cases'],sort_keys=True).encode()).hexdigest(),
            resultSHA256=hashlib.sha256(json.dumps(rust,sort_keys=True).encode()).hexdigest(),
            scope='Live unchanged Swift directory traversal/recent list and calendar aggregation vs Foundation-backed Rust. Hidden flags/dotfiles, natural sorting, depth/item bounds, symlinks, summary classification, modification ordering, time zones, DST and week/year edges. No native UI, user preferences, real-user folder scan or Windows workspace implementation.')
        (OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
