export const meta = {
  name: 'madi-feature-pipeline',
  description: 'Build Madi (apps/macos) features end-to-end with full multi-agent verification: parallel scout → parallel build → coordinated integrate (authority build + tests) → quark forward-verify (배선율/완수도) → adversarial refute → report.',
  whenToUse: 'Implementing one or more Madi macOS SwiftUI features and you want the established pipeline: parallel new-file builders, a single coordinated integrator, quark forward-check, and per-feature adversarial refute. Pass args.features = [{key, prompt}] to choose features; with no args it runs the 5 "for Human" ideas (open-loops, personal-vocabulary, explorer-feed, prep-brief, listen-review). The workflow leaves a verified WORKING TREE (it never commits) for the session to review/commit/PR.',
  phases: [
    { title: 'Scout', detail: 'read-only spec per feature' },
    { title: 'Build', detail: 'parallel new-file builders' },
    { title: 'Integrate', detail: 'single writer wires + make_app.sh build + swift test, fix to green' },
    { title: 'Quark', detail: 'forward-verify 배선율 100% + no 완수도 regression' },
    { title: 'Refute', detail: 'parallel adversarial review, verify findings vs code' },
    { title: 'Fix', detail: 'integrator resolves refute-confirmed blockers, re-green' },
  ],
}

const ROOT = '/Users/jupitersong/antigravity/madi'
const APP = ROOT + '/apps/macos/Sovereign'
const QDIR = '/Users/jupitersong/antigravity/quark'
const QCFG = 'configs/sovereign_whisper_app.mjs'

// ── Madi architecture facts (accumulated) so agents don't re-discover the basics ──
const CONTEXT = `Madi = on-device (sovereign) Korean meeting-intelligence macOS SwiftUI app. Repo ${ROOT}, sources ${APP}. Verify against real code; the notes below are a map, not gospel.
- Entry: Sovereign/SovereignApp.swift (@main, @State session/downloader). UI/ContentView.swift = mainLayout ZStack( HStack(explorer | transcriptPane | sidePanel) + ⌘K palette overlay ); summarySheet, qaBlock (이 회의 / 전체 워크스페이스 RAG toggle), field() helper, calendarBlock, LiveActionRailView, sidePanel toggles (A.I 요약 / 라이브 액션 추출 / 자막 오버레이).
- SessionController.swift (@MainActor @Observable): transcript:TranscriptStore (Line{speaker:Int,start,end:Double,words:[Word{t0,t1,text,conf}],overlapSpeakers,translations:[String:String],editedText}); speakerNames; voiceprintsDir(<name>.vec); autoSaveFolder + workspace:WorkspaceTree; sourceMediaURL + linePlayer (click-to-play, file sessions); calendar:CalendarBridge; liveRailItems + liveRailEnabled (≥16GB gate liveRailCapable); meetingSummary/meetingTitle; autoSaveMarkdown/autoSaveSummaryMarkdown; ensureSummaryEngine/ensureTranslateEngine (ONE model resident — summary kills translate); editLine; attributedLines.
- Transcript/: TranscriptArchive(parse .md→Lines), Exporters(markdown/srt/vtt/json/csv), SummaryDeck(html), Retrieval + WorkspaceRetrieval(cross-meeting), PeopleAnalytics, EnergyArc, TitleGenerator, PIIRedactor, LiveActionRail, EditorCuts(EditorSettings, chapters). Engine/: EngineProcess(DIAR_MAXK env), SummaryEngine + TranslateEngine(DNA3 LLM, on-device; .ask/.summarize/.generateTitle/.extractActions emit via onResult(tag,text)). Audio/: AudioCapture+Segmenter, AudioDecode(AVAudioFile + AVAssetReader for video), LinePlayer. UI/: WorkspaceExplorer(file tree + 파일/사람 tabs), PeopleDashboard, TranscriptView(onPlay/playingLine), CaptionOverlay, Theme.
- BUILD AUTHORITY: the real app build is apps/macos/scripts/make_app.sh (explicit SRCS array — EVERY new .swift file MUST be added there or it won't compile into the app). swiftc -typecheck alone is NOT authoritative (it has missed capture/shadow errors the -O build caught). Foundation-only cores (no SwiftUI/AppKit import) ALSO go in apps/macos/Package.swift SovereignCore sources to gain headless XCTest (Tests/SovereignCoreTests).
- QUARK (config ${QCFG}, srcDir=apps/macos, @main=Sovereign/SovereignApp.swift): use './q.sh classify' NOT regen (quarkify doesn't parse .swift). INVARIANT: 배선율 must stay 100% — every new .swift file must be type-referenced from the @main graph (a View instantiated by a parent View reachable from ContentView; a model referenced by a wired file). An unwired new file drops 배선율 below 100% = FAIL.`

const features = (typeof args === 'object' && args && Array.isArray(args.features) && args.features.length)
  ? args.features
  : [
    { key: 'open-loops', prompt: `OPEN LOOPS — a cross-meeting commitment tracker. Aggregate action items + open questions from EVERY archived .md in the workspace (WorkspaceTree + TranscriptArchive.parse, like PeopleAnalytics/WorkspaceRetrieval), and surface the UNRESOLVED ones: owner, source meeting + date, age ("12일째 후속 없음"), and whether a later meeting re-mentioned it (heuristic keyword/owner overlap). Reuse LiveActionRail's [결정]/[액션]/[질문] parse shape if those are saved, else extract from the .md text. New: an aggregator (Foundation-only → core+tests) + a "열린 항목" view (a tab in the explorer OR a section). Pure on-device.` },
    { key: 'personal-vocabulary', prompt: `PERSONAL VOCABULARY — domain terms/names get right over time. When the user edits a transcript line (SessionController.editLine), capture the before→after token correction into a persisted on-device glossary; then post-process future transcript lines to auto-fix phonetically-similar mis-recognitions of those terms (e.g. a corrected proper noun). New: a glossary store + a correction pass (Foundation-only core → tests for the matching/replacement). Hooks: editLine to learn, and the live/file line pipeline to apply. Conservative (only high-confidence phonetic matches) so it never corrupts good text.` },
    { key: 'explorer-feed', prompt: `EXPLORER FEED — make the workspace tree read like a feed. For each transcript .md show a one-line gist (the first decision/summary line, or the title + first line) inline under the filename in WorkspaceExplorer rows, computed once and cached (avoid re-parsing every render). New: a small gist extractor (Foundation-only → tests) + render in WorkspaceExplorer. Reuse TranscriptArchive/SummaryDeck parsing.` },
    { key: 'prep-brief', prompt: `MEETING PREP BRIEF — walk in prepared. Before a recording (or when a calendar event is detected via CalendarBridge), surface a brief: prior decisions + open items for this meeting/these attendees (WorkspaceRetrieval over past .md + PeopleAnalytics for attendee-owned tasks). New: a brief builder (reuse retrieval/people) + a pre-record brief view/section. Ties Calendar + People + RAG together.` },
    { key: 'listen-review', prompt: `LISTEN-TO-REVIEW — confirm low-confidence words by ear, fast. In the detailed review navigator (the 검토 필요 flow over words with conf < Theme.confThreshold), add a mode that auto-plays each low-confidence word's audio span in sequence using the existing LinePlayer (file-transcribed sessions only, where sourceMediaURL exists) and advances. New: wire LinePlayer + the review index together + a small control. Reuse click-to-play infra.` },
  ]

log(`madi-feature-pipeline: ${features.length} feature(s) → scout → build → integrate → quark → refute. Leaves a verified WORKING TREE (no commit).`)

// ── schemas ──
const SPEC = { type: 'object', properties: {
  feature: { type: 'string' }, feasibility: { type: 'string', enum: ['build-now-newfile', 'build-now-shared', 'needs-groundwork'] },
  summary: { type: 'string' }, newFiles: { type: 'array', items: { type: 'string' } },
  foundationOnlyFiles: { type: 'array', items: { type: 'string' }, description: 'new files with NO SwiftUI/AppKit import (→ Package.swift SovereignCore + XCTest)' },
  sharedWiring: { type: 'array', items: { type: 'string', description: 'exact file:symbol where ContentView/SessionController/etc. must be touched' } },
  plan: { type: 'array', items: { type: 'string' } }, risks: { type: 'string' }, verify: { type: 'string' },
}, required: ['feature', 'feasibility', 'summary', 'newFiles', 'plan', 'verify'] }

const BUILD = { type: 'object', properties: {
  feature: { type: 'string' }, files: { type: 'array', items: { type: 'string' } },
  foundationOnlyFiles: { type: 'array', items: { type: 'string' } },
  testFiles: { type: 'array', items: { type: 'string' } },
  wiring: { type: 'array', items: { type: 'object', properties: { file: { type: 'string' }, anchor: { type: 'string' }, code: { type: 'string' }, note: { type: 'string' } }, required: ['file', 'anchor', 'code'] } },
  selfReview: { type: 'string' }, risks: { type: 'string' },
}, required: ['feature', 'files', 'wiring', 'selfReview'] }

const INTEGRATE = { type: 'object', properties: {
  applied: { type: 'array', items: { type: 'string' }, description: 'wiring + registrations applied' },
  buildOk: { type: 'boolean' }, testCount: { type: 'string' }, typecheckErrors: { type: 'number' },
  fixes: { type: 'array', items: { type: 'string' }, description: 'compile/test errors fixed during integration' },
  notes: { type: 'string' },
}, required: ['buildOk', 'notes'] }

const QUARK = { type: 'object', properties: {
  wiredPct: { type: 'string', description: '배선율, must be 100.0%' }, completionPct: { type: 'string' },
  unwiredNewFiles: { type: 'array', items: { type: 'string' }, description: 'new .swift files NOT reachable from @main (배선율 < 100% → FAIL)' },
  pass: { type: 'boolean', description: 'true only if 배선율 100% and no completion regression' }, notes: { type: 'string' },
}, required: ['wiredPct', 'pass', 'notes'] }

const VERDICT = { type: 'object', properties: {
  feature: { type: 'string' }, verdict: { type: 'string', enum: ['pass', 'concern', 'fail'] },
  issues: { type: 'array', items: { type: 'object', properties: { severity: { type: 'string', enum: ['blocker', 'major', 'minor'] }, claim: { type: 'string' }, evidence: { type: 'string', description: 'file:line + quoted code' }, fix: { type: 'string' } }, required: ['severity', 'claim', 'evidence', 'fix'] } },
  notes: { type: 'string' },
}, required: ['feature', 'verdict', 'issues'] }

// ── Phase 1: Scout (parallel, read-only) ──
phase('Scout')
const specs = (await parallel(features.map((f) => () =>
  agent(`${CONTEXT}\n\nYou are a READ-ONLY feasibility scout for ONE Madi feature. Read the real files; report exact new files, shared wiring points (file:symbol), Foundation-only cores, an implementation plan, risks, and how to verify. Do NOT edit anything.\n\nFEATURE — ${f.key}: ${f.prompt}`,
    { label: `scout:${f.key}`, phase: 'Scout', agentType: 'Explore', schema: SPEC })
))).filter(Boolean)

// ── Phase 2: Build (parallel, NEW FILES ONLY) ──
phase('Build')
const BUILD_RULES = `${CONTEXT}\n\nBuild ONE feature. HARD CONSTRAINTS:\n- Create ONLY your new file(s) (Write tool). DO NOT edit ANY existing file (ContentView/SessionController/SovereignApp/make_app.sh/Package.swift/Theme/etc.) — the integrator applies all shared wiring afterward, so two parallel builders never touch the same file.\n- READ real type signatures first (Line/Word, Theme.* tokens that ACTUALLY exist, SessionController public API, the cores you reuse) — do not guess; match exactly.\n- Foundation-only logic cores (no SwiftUI/AppKit import) are preferred for testability — author a matching XCTest under apps/macos/Tests/SovereignCoreTests/ for any pure core.\n- Korean UI strings; two font weights; reuse Theme tokens so light/dark both work.\nRETURN the new file path(s) incl. tests, which are Foundation-only, and the EXACT wiring the integrator must apply (file, precise anchor, literal Swift snippet).`
const built = (await parallel(specs.map((s) => () =>
  agent(`${BUILD_RULES}\n\n=== FEATURE: ${s.feature} ===\nSpec:\n${JSON.stringify(s, null, 2)}`,
    { label: `build:${s.feature}`, phase: 'Build', schema: BUILD })
))).filter(Boolean)

// ── Phase 3: Integrate (SINGLE writer — wire, register, AUTHORITY build, tests, fix to green) ──
phase('Integrate')
const INTEGRATE_RULES = `${CONTEXT}\n\nYou are the SINGLE coordinated writer. Apply EVERY builder's wiring to the shared files at the stated disjoint anchors, and register EVERY new .swift file:\n- add ALL new files to apps/macos/scripts/make_app.sh SRCS (this is MANDATORY — unregistered files don't compile into the app).\n- add Foundation-only cores to apps/macos/Package.swift SovereignCore sources (so their XCTest runs).\nThen verify with the AUTHORITY build, not just typecheck:\n  cd ${ROOT}/apps/macos && bash scripts/make_app.sh   (the real -O build + sign)\n  cd ${ROOT}/apps/macos && swift test\nFIX every compile error and test failure (read the error, edit the source, rebuild) until BOTH are green. swiftc -typecheck is a fast pre-check only — make_app.sh is authoritative (it has caught capture-before-declared / shadowing the typecheck missed). Do NOT git commit or push — leave the verified working tree for the user. Report what you applied, the final build/test status, and any fixes.`
const integration = await agent(`${INTEGRATE_RULES}\n\nBUILDERS OUTPUT:\n${JSON.stringify(built, null, 2)}`,
  { label: 'integrate', phase: 'Integrate', schema: INTEGRATE, effort: 'high' })

// ── Phase 4: Quark forward-verify (배선율 100% + no completion regression) ──
phase('Quark')
const quark = await agent(`Forward-verify the Madi swift app with quark. Run:\n  cd ${QDIR} && ./q.sh classify ${QCFG}\n  cd ${QDIR} && ./q.sh gaps ${QCFG}\nCONFIRM the INVARIANT: 배선율(wired) must be 100.0% — EVERY new .swift file added this run must be type-referenced from the @main SovereignApp.swift graph. If any new file is unwired (배선율 < 100%), that is a FAIL — name the file(s) and why they're unreachable. Report 배선율, 완수도(completion) %, and pass=true ONLY if 배선율 is 100% and completion did not regress. Use classify NOT regen (quarkify doesn't parse .swift). New files list: ${JSON.stringify(built.flatMap((b) => b.files || []))}.`,
  { label: 'quark:forward', phase: 'Quark', schema: QUARK })

// ── Phase 5: Refute (parallel adversarial, verify findings vs code) ──
phase('Refute')
const REFUTE_RULES = `${CONTEXT}\n\nADVERSARIALLY refute ONE feature AS IMPLEMENTED in the current WORKING TREE (read the actual files under ${APP}, not a commit). Try to find blockers / regressions / lifecycle / concurrency / memory bugs. Cite file:line + quoted code for every issue. CRUCIAL — verify each finding against the code and REJECT false positives (the integrator will trust your verdict): e.g. ProcessInfo.physicalMemory is FIXED installed RAM (not available memory); @MainActor methods are serialized (no interleave); @Observable propagates through NSHostingView on macOS 14+; a retain cycle on the single app-lifetime SessionController is benign. Speculative nits = 'minor'; only concrete code-grounded defects are 'major'/'blocker'. Return 'pass' if you genuinely can't find a real defect.`
const verdicts = (await parallel(built.map((b) => () =>
  agent(`${REFUTE_RULES}\n\nFEATURE: ${b.feature}\nFiles: ${JSON.stringify(b.files)}\nWiring applied: ${JSON.stringify(b.wiring)}`,
    { label: `refute:${b.feature}`, phase: 'Refute', agentType: 'Explore', schema: VERDICT })
))).filter(Boolean)
const blockers = verdicts.flatMap((v) => (v.issues || []).filter((i) => i.severity === 'blocker' || i.severity === 'major').map((i) => ({ feature: v.feature, ...i })))

// ── Phase 6: Fix refute-confirmed blockers, re-green (only if any) ──
let fixIntegration = null
if (blockers.length) {
  phase('Fix')
  fixIntegration = await agent(`${CONTEXT}\n\nThe adversarial review found these REAL blocker/major issues in the working tree (false positives already filtered). Fix each in the source, then re-run the AUTHORITY build (bash apps/macos/scripts/make_app.sh) + swift test until green. Do NOT commit. Report fixes + final status.\n\nBLOCKERS:\n${JSON.stringify(blockers, null, 2)}`,
    { label: 'integrate:fix', phase: 'Fix', schema: INTEGRATE, effort: 'high' })
}

return {
  features: features.map((f) => f.key),
  specs, built,
  integration, quark, verdicts, blockers, fixIntegration,
  summary: `${features.length} feature(s) implemented in the working tree. build=${(fixIntegration || integration).buildOk}, quark배선율=${quark.wiredPct} (pass=${quark.pass}), refute blockers fixed=${blockers.length}. Review the working tree, then commit + PR.`,
}
