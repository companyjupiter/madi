// types.ts — the engine event contract, typed.
// MIRRORS docs/EVENTS.md. Keep in sync with metal/transcribe.zig ev* emitters.
// Unknown event types / fields are ignored by the reducer (forward-compat).

export interface MetaEvent { t: 'meta'; v: number; model: string; lang: number; sr: number }
export interface ReadyEvent { t: 'ready' }
export interface WordEvent { t: 'word'; t0: number; t1: number; conf: number; spk: number; text: string }
export interface SegEvent {
  t: 'seg'; idx: number; t0: number; t1: number; dropped: boolean
  fallback: string; temp: number              // reserved → real in P1
  tok_s: number; enc_ms: number; dec_ms: number; passes: number
  text: string
  bias_hits?: string[]                          // reserved → real in P3
}
export interface SpkSegEvent { t: 'spk_seg'; t0: number; spk: number; text: string }
export interface DiarEvent { t: 'diar'; speakers: number; silhouette: number; sep: number; tau: number; segments: number }
export interface EndEvent { t: 'seg_end' | 'flush_end' }

export type EngineEvent =
  | MetaEvent | ReadyEvent | WordEvent | SegEvent | SpkSegEvent | DiarEvent | EndEvent

// ── Derived dashboard state (what the panels render) ─────────────────────────
export interface SessionState {
  meta?: MetaEvent
  ready: boolean
  words: WordEvent[]
  segs: SegEvent[]
  spkSegs: SpkSegEvent[]
  diar?: DiarEvent
  ended: boolean
}

export const emptySession = (): SessionState => ({
  ready: false, words: [], segs: [], spkSegs: [], ended: false,
})

/** Fold one event into the session (pure — easy to unit-test / replay live). */
export function reduce(s: SessionState, e: EngineEvent): SessionState {
  switch (e.t) {
    case 'meta': return { ...s, meta: e }
    case 'ready': return { ...s, ready: true }
    case 'word': return { ...s, words: [...s.words, e] }
    case 'seg': return { ...s, segs: [...s.segs, e] }
    case 'spk_seg': return { ...s, spkSegs: [...s.spkSegs, e] }
    case 'diar': return { ...s, diar: e }
    case 'seg_end':
    case 'flush_end': return { ...s, ended: true }
    default: return s
  }
}

// Whisper language-token id → human label (the ids the engine SEEDs).
export const LANG: Record<number, string> = {
  0: '자동감지', 50264: '한국어', 50259: '영어', 50260: '중국어', 50266: '일본어',
}
export const langLabel = (id?: number) => (id == null ? '—' : LANG[id] ?? `lang#${id}`)
