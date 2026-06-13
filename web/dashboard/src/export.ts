// export.ts — client-side transcript export from the in-session events.
// A compact TS port of tools/srt_broadcast.py's cue segmentation + tools/
// captions.py's SRT/VTT/HTML renderers, so the dashboard can download a
// broadcast-grade caption file for the current session with no server.
// (iTT/FCPXML stay in the Python tool — niche, XML-heavy.)
import { SessionState, WordEvent } from './types'

const SPK_COLORS = ['#007AFF', '#FF9500', '#28CD41', '#AF52DE', '#FF2D55', '#30B0C7', '#FF3B30', '#5856D6']
const LOW_CONF = 0.55

function dwidth(s: string): number {
  let w = 0
  for (const ch of s) {
    const o = ch.codePointAt(0)!
    w += (o >= 0x1100 && o <= 0x115f) || (o >= 0x2e80 && o <= 0xa4cf) || (o >= 0xac00 && o <= 0xd7a3)
      || (o >= 0xf900 && o <= 0xfaff) || (o >= 0xff00 && o <= 0xff60) || (o >= 0xffe0 && o <= 0xffe6) ? 2 : 1
  }
  return w
}

function fillLines(words: string[], maxLine: number): string[] | null {
  const lines: string[] = []
  let cur = ''
  for (const w of words) {
    const nxt = (cur + ' ' + w).trim()
    if (dwidth(nxt) <= maxLine) cur = nxt
    else {
      if (cur) lines.push(cur)
      cur = w
      if (dwidth(w) > maxLine) return null
    }
  }
  if (cur) lines.push(cur)
  return lines.length <= 2 ? lines : null
}

interface Cue { s: number; e: number; lines: string[] }

export function buildCues(words: WordEvent[], cps = 17, maxLine = 42, minDur = 0.83, maxDur = 7, minGap = 0.083): Cue[] {
  const cues: Cue[] = []
  let cur: WordEvent[] = []
  const SENT = /[.?!。…?!]$/
  const flush = (ws: WordEvent[], nxtStart: number | null) => {
    if (!ws.length) return
    const txt = ws.map((w) => w.text.trim()).join(' ').trim()
    const s = ws[0].t0
    let e = ws[ws.length - 1].t1
    const chars = dwidth(txt.replace(/\s/g, ''))
    e = Math.max(e, s + chars / cps, s + minDur)
    e = Math.min(e, s + maxDur)
    e = Math.max(e, s + 0.05)
    if (nxtStart != null) e = Math.min(e, nxtStart - minGap)
    cues.push({ s, e, lines: fillLines(txt.split(/\s+/), maxLine) ?? [txt] })
  }
  words.forEach((w, i) => {
    const cand = [...cur, w]
    const tooLong = fillLines(cand.map((x) => x.text.trim()), maxLine) == null
    const dur = w.t1 - cand[0].t0
    const txt = cand.map((x) => x.text.trim()).join(' ')
    const tooFast = dur > 0 && dwidth(txt.replace(/\s/g, '')) / dur > cps && cand.length > 1
    if ((tooLong || tooFast) && cur.length) { flush(cur, w.t0); cur = [w] }
    else cur = cand
    if (cur.length && SENT.test(cur[cur.length - 1].text.trim())) {
      flush(cur, i + 1 < words.length ? words[i + 1].t0 : null)
      cur = []
    }
  })
  flush(cur, null)
  return cues
}

const pad = (n: number, w = 2) => String(n).padStart(w, '0')
function tc(t: number, sep: string) {
  const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = Math.floor(t % 60), ms = Math.round((t - Math.floor(t)) * 1000)
  return `${pad(h)}:${pad(m)}:${pad(s)}${sep}${pad(ms % 1000, 3)}`
}

export function toSRT(cues: Cue[]): string {
  return cues.map((c, i) => `${i + 1}\n${tc(c.s, ',')} --> ${tc(c.e, ',')}\n${c.lines.join('\n')}\n`).join('\n')
}
export function toVTT(cues: Cue[]): string {
  return 'WEBVTT\n\n' + cues.map((c, i) => `${i + 1}\n${tc(c.s, '.')} --> ${tc(c.e, '.')}\n${c.lines.join('\n')}\n`).join('\n')
}

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
export function toHTML(s: SessionState): string {
  const segs = [...s.spkSegs].sort((a, b) => a.t0 - b.t0)
  const spkAt = (t: number) => { let c = -1; for (const sg of segs) { if (sg.t0 <= t) c = sg.spk; else break } return c }
  const rows: { spk: number; words: WordEvent[] }[] = []
  let last = -2
  for (const w of s.words) { const sp = spkAt(w.t0); if (sp !== last) { rows.push({ spk: sp, words: [] }); last = sp } rows[rows.length - 1].words.push(w) }
  const body = rows.map((r) => {
    const c = r.spk >= 0 ? SPK_COLORS[r.spk % 8] : '#9DA7B3'
    const ws = r.words.map((w) => {
      const low = w.conf < LOW_CONF
      const st = `color:${low ? '#FF9F0A' : '#E6EDF3'};${low ? 'text-decoration:underline dotted;' : ''}`
      return `<span title="${(w.conf * 100).toFixed(0)}% · ${w.t0.toFixed(2)}s" style="${st}">${esc(w.text.trim())}</span>`
    }).join(' ')
    const ts = r.words[0]?.t0 ?? 0
    return `<div class="row"><span class="spk" style="color:${c};border-color:${c}">화자 ${r.spk >= 0 ? r.spk : '?'}</span><span class="ts">${pad(Math.floor(ts / 60))}:${pad(Math.floor(ts % 60))}</span><span class="tx">${ws}</span></div>`
  }).join('')
  return `<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>Sovereign 전사</title><style>
body{background:#0E1217;color:#E6EDF3;font-family:-apple-system,'Apple SD Gothic Neo','Noto Sans KR',sans-serif;max-width:860px;margin:0 auto;padding:28px;line-height:1.85}
h1{font-size:18px}.meta{color:#5C6773;font-size:12px;margin-bottom:20px}.row{display:flex;gap:10px;margin-bottom:14px;align-items:baseline}
.spk{font-size:11px;font-weight:700;border:1px solid;border-radius:6px;padding:0 7px;white-space:nowrap}.ts{color:#5C6773;font-size:11px;white-space:nowrap}.tx{flex:1}
.legend{color:#5C6773;font-size:11px;margin-top:24px;border-top:1px solid #283039;padding-top:10px}.legend b{color:#FF9F0A}</style></head>
<body><h1>Sovereign 전사</h1><div class="meta">${esc(s.meta?.model ?? '')} · ${s.words.length} 단어 · ${rows.length} 발화</div>${body}
<div class="legend"><b>호박색 밑줄</b> = 낮은 신뢰도(검토 권장). 단어에 마우스를 올리면 신뢰도·시각.</div></body></html>`
}

export function download(filename: string, content: string, mime: string) {
  const blob = new Blob([content], { type: mime })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url; a.download = filename; a.click()
  URL.revokeObjectURL(url)
}
