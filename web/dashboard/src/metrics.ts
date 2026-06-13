// metrics.ts — derive dashboard KPIs from session state. Pure functions.
import { SessionState, WordEvent } from './types'

export const LOW_CONF = 0.55 // matches app Theme+Conf.confThreshold

export interface Kpis {
  durationS: number
  words: number
  speakers: number
  avgConf: number
  lowConfPct: number
  tokS: number          // mean decode tok/s across segs
  rtf: number           // real-time factor = compute / audio
  fallbacks: number     // segs that needed a re-decode (P1)
  dropped: number       // hallucination-guarded segs
}

export function kpis(s: SessionState): Kpis {
  const durationS = s.segs.length ? Math.max(...s.segs.map((g) => g.t1)) : 0
  const words = s.words.length
  const speakers = s.diar?.speakers ?? (s.spkSegs.length ? new Set(s.spkSegs.map((x) => x.spk)).size : 0)
  const avgConf = words ? s.words.reduce((a, w) => a + w.conf, 0) / words : 1
  const lowConfPct = words ? (100 * s.words.filter((w) => w.conf < LOW_CONF).length) / words : 0
  const tokS = s.segs.length ? s.segs.reduce((a, g) => a + g.tok_s, 0) / s.segs.length : 0
  const computeMs = s.segs.reduce((a, g) => a + g.enc_ms + g.dec_ms, 0)
  const rtf = durationS > 0 ? computeMs / 1000 / durationS : 0
  const fallbacks = s.segs.filter((g) => g.fallback && g.fallback !== 'none').length
  const dropped = s.segs.filter((g) => g.dropped).length
  return { durationS, words, speakers, avgConf, lowConfPct, tokS, rtf, fallbacks, dropped }
}

/** Per-speaker talk time (s) and word counts, from spk_seg + word streams. */
export function perSpeaker(s: SessionState) {
  const map = new Map<number, { talkS: number; words: number; chars: number }>()
  const segs = [...s.spkSegs].sort((a, b) => a.t0 - b.t0)
  segs.forEach((seg, i) => {
    const end = i + 1 < segs.length ? segs[i + 1].t0 : (s.segs.length ? Math.max(...s.segs.map((g) => g.t1)) : seg.t0)
    const e = map.get(seg.spk) ?? { talkS: 0, words: 0, chars: 0 }
    e.talkS += Math.max(0, end - seg.t0)
    e.chars += seg.text.length
    map.set(seg.spk, e)
  })
  // attribute words to nearest spk_seg for word counts
  for (const w of s.words) {
    const sp = speakerAt(segs, w.t0)
    if (sp == null) continue
    const e = map.get(sp) ?? { talkS: 0, words: 0, chars: 0 }
    e.words += 1; map.set(sp, e)
  }
  return [...map.entries()].map(([spk, v]) => ({ spk, ...v })).sort((a, b) => a.spk - b.spk)
}

function speakerAt(segs: { t0: number; spk: number }[], t: number): number | null {
  let cur: number | null = null
  for (const s of segs) { if (s.t0 <= t) cur = s.spk; else break }
  return cur
}

/** Confidence histogram (10 bins 0..1). */
export function confHistogram(words: WordEvent[], bins = 10): number[] {
  const h = new Array(bins).fill(0)
  for (const w of words) { const b = Math.min(bins - 1, Math.floor(w.conf * bins)); h[b]++ }
  return h
}
