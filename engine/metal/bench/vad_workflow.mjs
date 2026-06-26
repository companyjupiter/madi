export const meta = {
  name: 'vad-tuning-analysis',
  description: 'Per-language × per-speaker VAD_PROB analysis: cell deep-dives (FA/miss mechanism + per-file robustness), synthesis, methodology critique',
  phases: [
    { title: 'Cell analysis', detail: 'one agent per language×speaker cell — optimum + mechanism + robustness' },
    { title: 'Synthesis', detail: 'final recommendation table + code-default proposal' },
    { title: 'Critique', detail: 'adversarial methodology review' },
  ],
}

const DIR = '/Users/jupitersong/antigravity/madi/engine/metal'
const CAMP = `${DIR}/bench/runs/vad_campaign.jsonl`      // {prob,fid,group,bucket,nspk_ref,der}
const COMP = `${DIR}/bench/runs/vad_components.jsonl`    // + {scored,miss,fa,conf}
const FLEURS = `${DIR}/bench/runs/fleurs_vad_sweep.jsonl`// {prob,result:"CER=.. WER=.. n=.. empty=.."}
const PHASE2LOG = `${DIR}/bench/runs/vad_phase2.log`     // natural-KO retention tables

const CELL_SCHEMA = {
  type: 'object',
  required: ['cell', 'n_files', 'per_prob', 'optimum_prob', 'robust_range', 'mechanism', 'robustness', 'recommendation'],
  properties: {
    cell: { type: 'string' },
    n_files: { type: 'integer' },
    per_prob: { type: 'string', description: 'table: prob → mean DER, mean miss%, mean FA%, mean conf% (of scored time)' },
    optimum_prob: { type: 'number' },
    robust_range: { type: 'string', description: 'probs within +0.5pp of best' },
    mechanism: { type: 'string', description: 'WHY this optimum: FA-dominated (high prob helps) vs miss-dominated (low prob helps), grounded in the miss/FA decomposition' },
    robustness: { type: 'string', description: 'per-file win-rate of optimum vs prob=0.5 (fraction of files where optimum <= 0.5 DER); is the win robust or outlier/mean-driven?' },
    recommendation: { type: 'string', description: 'recommended VAD_PROB for this cell + one-line justification' },
  },
}

const cells = [
  { key: 'EN-conv/1', group: 'vox', bucket: '1', desc: 'English close-mic conversational, single speaker (VoxConverse, 22 files)' },
  { key: 'EN-conv/2', group: 'vox', bucket: '2', desc: 'English close-mic conversational, 2 speakers (VoxConverse, 44 files)' },
  { key: 'EN-conv/multi', group: 'vox', bucket: 'multi', desc: 'English close-mic conversational, 3+ speakers (VoxConverse, 150 files)' },
  { key: 'EN-farfield/multi', group: 'ami', bucket: 'multi', desc: 'English FAR-FIELD meeting, 4 speakers (AMI ES2004a, 1 file, 17 min)' },
  { key: 'KO-fixtures', group: 'ko', bucket: 'all', desc: 'Korean clean TTS fixtures ko1/ko2/ko4 (1/2/4 speakers)' },
]

phase('Cell analysis')
const cellResults = await parallel(cells.map(c => () =>
  agent(
`You are analyzing the VAD_PROB sweep for ONE cell of a speech-diarization quality benchmark.

CELL: ${c.key} — ${c.desc}
Filter rows by: group=="${c.group}"${c.bucket === 'all' ? '' : ` AND bucket=="${c.bucket}"`}  (for KO-fixtures use all three ko files).

DATA FILES (JSONL, one object per line):
- DER per (prob,file):      ${CAMP}
- components per (prob,file): ${COMP}  (fields: scored,miss,fa,conf in SECONDS; der in %)

Use Bash with python3 to compute. Steps:
1. For each VAD_PROB in {0.2,0.35,0.5,0.65,0.8,0.9}: mean DER, and mean component % of scored time:
   miss% = 100*sum(miss)/sum(scored), fa% = 100*sum(fa)/sum(scored), conf% = 100*sum(conf)/sum(scored).
2. Find optimum_prob (min mean DER) and robust_range (all probs within +0.5pp of best).
3. Mechanism: inspect how miss% and fa% move with prob. Higher VAD_PROB = stricter speech gate
   ⇒ fewer false-speech windows (FA↓) but quiet/distant real speech dropped (miss↑). State which
   dominates THIS cell and why that produces the observed optimum.
4. Robustness: per-file, compare each file's DER at optimum_prob vs at 0.5. Report win-rate
   (fraction with optimum <= 0.5) and whether the mean improvement is broad or driven by a few outliers.
5. recommendation: the VAD_PROB you'd ship for this cell.

Return ONLY the structured object. Ground every number in the data you computed.`,
    { schema: CELL_SCHEMA, label: `cell:${c.key}`, phase: 'Cell analysis' }
  ).then(r => ({ ...r, _key: c.key }))
))

const goodCells = cellResults.filter(Boolean)

phase('Synthesis')
const synthesis = await agent(
`You are the synthesis lead for a per-language × per-speaker VAD threshold (VAD_PROB) study for a
sovereign Whisper diarization+ASR engine. The default is currently hardcoded 0.5 for everything.

PER-CELL RESULTS (DER, English + clean Korean):
${JSON.stringify(goodCells, null, 2)}

ADDITIONAL EVIDENCE — read these files yourself with Bash/Read:
- Korean transcription CER vs VAD_PROB (FLEURS-ko, single-speaker read-speech): ${FLEURS}
  (each line: prob + "CER=.. WER=.. n=.. empty=.."; empty>0 means utterances were chunk-skipped = too strict)
- Natural Korean speech-RETENTION curves (no ground truth) in ${PHASE2LOG} — search for "KO-natural":
  hankit (clean monologue), clova (49min real meeting), devart (real podcast). Each shows window-kept%
  and frame-speech% per threshold; the "90%-retention knee" is the prob where real speech starts being cut.

Produce:
1. A recommendation TABLE: rows = (language × speaker-setting), columns = recommended VAD_PROB,
   expected DER (or CER) vs the 0.5 default, and the robust range. Cover:
   EN close-mic 1/2/multi, EN far-field meeting, KO clean, KO natural-conversational, KO read-speech.
2. The single most important finding (the directional split between close-mic/clean and far-field/quiet).
3. A concrete code-default proposal: should the shipped default change from 0.5? Per-mode? (e.g. a
   far-field/meeting profile vs a clean/dictation profile). Give exact VAD_PROB values and which env
   the app should set (VAD_PROB). Note interactions with DIAR_VAD_SP if relevant.
4. Honest caveats (sample sizes, fixture vs real audio).

Be concrete and numeric. This goes straight to a principal engineer.`,
  { label: 'synthesis', phase: 'Synthesis' }
)

phase('Critique')
const critique = await agent(
`Adversarially critique this VAD_PROB study's METHODOLOGY and conclusions. Be skeptical and specific.

SYNTHESIS:
${synthesis}

PER-CELL DATA:
${JSON.stringify(goodCells, null, 2)}

You may read the data files under ${DIR}/bench/runs/ to verify claims. Consider:
- The far-field conclusion rests on AMI ES2004a (n=1). Is the mechanism (miss↑ at high prob) strong
  enough to generalize, or is it overfit? What would falsify it?
- KO DER is from clean TTS fixtures (n=1 each) — do they justify any KO DER claim, or only the
  retention/CER evidence?
- FLEURS read-speech is single-chunk — is it even sensitive to VAD_PROB? Does empty-count tell us anything?
- Is "VoxConverse wants high prob" robust across files or mean-driven? Any Simpson's-paradox risk in bucketing?
- Anything in the pipeline (OSD overlap rows, silero clipping, auto-K) that confounds attributing DER
  changes purely to VAD_PROB?

Output: (a) the 3 strongest threats to validity, ranked; (b) for each, whether it changes the
recommendation; (c) the single highest-value follow-up measurement.`,
  { label: 'critique', phase: 'Critique' }
)

return { cells: goodCells, synthesis, critique }
