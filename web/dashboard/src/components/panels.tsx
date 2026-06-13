import { useEffect, useRef } from 'react'
import { SessionState } from '../types'
import { LOW_CONF, perSpeaker, confHistogram, kpis } from '../metrics'
import { Donut, Bars, Histogram, Timeline, spkColor } from './charts'

function Panel({ title, sub, children, style }:
  { title: string; sub?: string; children: React.ReactNode; style?: React.CSSProperties }) {
  return (
    <section className="panel" style={style}>
      <div className="panel-h"><span>{title}</span>{sub && <span className="sub">{sub}</span>}</div>
      <div className="panel-b">{children}</div>
    </section>
  )
}

const speakerAt = (segs: { t0: number; spk: number }[], t: number): number => {
  let cur = -1
  for (const s of segs) { if (s.t0 <= t) cur = s.spk; else break }
  return cur
}

// ── 전사 (live transcript, speaker-colored, low-confidence amber) ─────────────
export function TranscriptPanel({ s }: { s: SessionState }) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => { ref.current?.scrollTo({ top: ref.current.scrollHeight }) }, [s.words.length])
  const segs = [...s.spkSegs].sort((a, b) => a.t0 - b.t0)
  const rows: { spk: number; words: typeof s.words }[] = []
  for (const w of s.words) {
    const sp = speakerAt(segs, w.t0)
    const last = rows[rows.length - 1]
    if (!last || last.spk !== sp) rows.push({ spk: sp, words: [w] })
    else last.words.push(w)
  }
  return (
    <section className="panel" style={{ gridArea: 'tx' }}>
      <div className="panel-h">
        <span>전사 <span className="sub">화자 색상 · 저신뢰 호박색</span></span>
        <span className="sub">{s.words.length} 단어</span>
      </div>
      <div className="panel-b" ref={ref} style={{ lineHeight: 1.9 }}>
        {rows.length === 0 && <span style={{ color: 'var(--text-3)' }}>대기 중…</span>}
        {rows.map((r, i) => (
          <div key={i} style={{ marginBottom: 10 }}>
            <span style={{ display: 'inline-block', fontSize: 11, fontWeight: 700, color: spkColor(r.spk),
              border: `1px solid ${spkColor(r.spk)}`, borderRadius: 6, padding: '0 7px', marginRight: 8 }}>
              화자 {r.spk < 0 ? '?' : r.spk}
            </span>
            {r.words.map((w, j) => {
              const low = w.conf < LOW_CONF
              return (
                <span key={j} title={`${(w.conf * 100).toFixed(0)}% · ${w.t0.toFixed(2)}s`}
                  style={{ color: low ? 'var(--low-conf)' : 'var(--text)',
                    textDecoration: low ? 'underline dotted' : 'none', textUnderlineOffset: 3 }}>
                  {w.text}{' '}
                </span>
              )
            })}
          </div>
        ))}
      </div>
    </section>
  )
}

// ── 화자 분석 (talk share donut + per-speaker bars + timeline) ────────────────
export function SpeakerPanel({ s }: { s: SessionState }) {
  const ps = perSpeaker(s)
  const dur = s.segs.length ? Math.max(...s.segs.map((g) => g.t1)) : 0
  const donut = ps.map((p) => ({ label: `화자 ${p.spk}`, value: p.talkS, color: spkColor(p.spk) }))
  const bars = ps.map((p) => ({ label: `화자 ${p.spk}`, value: p.talkS, color: spkColor(p.spk) }))
  return (
    <Panel title="화자 분석" sub={s.diar ? `silhouette ${s.diar.silhouette.toFixed(2)} · 분리도 ${s.diar.sep.toFixed(2)}` : ''}
      style={{ gridArea: 'spk' }}>
      <div style={{ display: 'flex', gap: 16, alignItems: 'center', marginBottom: 14 }}>
        {donut.length > 0 && <Donut data={donut} />}
        <div style={{ flex: 1 }}><Bars data={bars} fmt={(v) => `${v.toFixed(0)}s`} /></div>
      </div>
      <div style={{ fontSize: 11, color: 'var(--text-3)', marginBottom: 6 }}>발화 타임라인</div>
      <Timeline segs={s.spkSegs} duration={dur} speakers={ps.map((p) => p.spk)} />
    </Panel>
  )
}

// ── 품질 (confidence histogram + low-conf words + diar quality) ───────────────
export function QualityPanel({ s }: { s: SessionState }) {
  const hist = confHistogram(s.words)
  const low = s.words.filter((w) => w.conf < LOW_CONF).sort((a, b) => a.conf - b.conf).slice(0, 24)
  const lowCutBin = Math.round(LOW_CONF * 10)
  const rescued = s.segs.filter((g) => g.fallback && g.fallback !== 'none')
  const minLp = s.segs.length ? Math.min(...s.segs.map((g) => g.avg_logprob ?? 0)) : 0
  const biasHits = [...new Set(s.segs.flatMap((g) => g.bias_hits ?? []))]
  return (
    <Panel title="품질 신호" sub={`임계 ${(LOW_CONF * 100).toFixed(0)}%`} style={{ gridArea: 'ql' }}>
      <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
        <div style={{ flex: 1, background: 'var(--panel-2)', borderRadius: 8, padding: '8px 10px' }}>
          <div style={{ fontSize: 11, color: 'var(--text-3)' }}>최저 avg_logprob</div>
          <div className="mono" style={{ fontSize: 16, fontWeight: 700, color: minLp < -1 ? 'var(--bad)' : minLp < -0.5 ? 'var(--warn)' : 'var(--good)' }}>{minLp.toFixed(2)}</div>
        </div>
        <div style={{ flex: 1, background: 'var(--panel-2)', borderRadius: 8, padding: '8px 10px' }}>
          <div style={{ fontSize: 11, color: 'var(--text-3)' }}>재디코드(rescue)</div>
          <div className="mono" style={{ fontSize: 16, fontWeight: 700, color: rescued.length ? 'var(--warn)' : 'var(--good)' }}>
            {rescued.length}{rescued.length > 0 && <span style={{ fontSize: 11, fontWeight: 400, color: 'var(--text-3)' }}> · {[...new Set(rescued.map((r) => r.fallback))].join('/')}</span>}
          </div>
        </div>
      </div>
      {biasHits.length > 0 && (
        <div style={{ marginBottom: 12 }}>
          <div style={{ fontSize: 11, color: 'var(--text-3)', marginBottom: 6 }}>적용된 용어 바이어싱 ({biasHits.length})</div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
            {biasHits.map((t, i) => (
              <span key={i} style={{ fontSize: 12, background: 'rgba(0,122,255,.15)', color: 'var(--accent)',
                border: '1px solid var(--accent)', borderRadius: 6, padding: '2px 8px' }}>{t}</span>
            ))}
          </div>
        </div>
      )}
      <div style={{ fontSize: 11, color: 'var(--text-3)', marginBottom: 6 }}>단어 신뢰도 분포 (0→100%)</div>
      <Histogram bins={hist} lowCutBin={lowCutBin} />
      <div style={{ fontSize: 11, color: 'var(--text-3)', margin: '14px 0 6px' }}>
        검토 권장 단어 <span style={{ color: 'var(--low-conf)' }}>({low.length})</span>
      </div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
        {low.length === 0 && <span style={{ color: 'var(--good)', fontSize: 12 }}>모두 높은 신뢰도 ✓</span>}
        {low.map((w, i) => (
          <span key={i} className="mono" title={`${w.t0.toFixed(2)}s`}
            style={{ fontSize: 12, background: 'var(--panel-2)', border: '1px solid var(--border)',
              borderRadius: 6, padding: '2px 7px', color: 'var(--low-conf)' }}>
            {w.text.trim()} <span style={{ color: 'var(--text-3)' }}>{(w.conf * 100).toFixed(0)}%</span>
          </span>
        ))}
      </div>
    </Panel>
  )
}

// ── 성능 (per-segment decode speed + encoder/decoder ms + RTF) ────────────────
export function PerfPanel({ s }: { s: SessionState }) {
  const k = kpis(s)
  const segBars = s.segs.map((g) => ({ label: `#${g.idx}`, value: g.tok_s, color: 'var(--accent)' }))
  return (
    <Panel title="성능" sub={`평균 ${k.tokS.toFixed(0)} tok/s · RTF ${k.rtf.toFixed(2)}×`} style={{ gridArea: 'pf' }}>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 14 }}>
        {[['인코더', s.segs.length ? (s.segs.reduce((a, g) => a + g.enc_ms, 0) / s.segs.length).toFixed(0) : '0', 'ms/청크'],
          ['디코더', s.segs.length ? (s.segs.reduce((a, g) => a + g.dec_ms, 0) / s.segs.length).toFixed(0) : '0', 'ms/청크'],
          ['청크 수', String(s.segs.length), '× 30s']].map(([l, v, u], i) => (
          <div key={i} style={{ background: 'var(--panel-2)', borderRadius: 8, padding: '8px 10px' }}>
            <div style={{ fontSize: 11, color: 'var(--text-3)' }}>{l}</div>
            <div className="mono" style={{ fontSize: 18, fontWeight: 700 }}>{v}<span style={{ fontSize: 10, color: 'var(--text-3)', fontWeight: 400 }}> {u}</span></div>
          </div>
        ))}
      </div>
      <div style={{ fontSize: 11, color: 'var(--text-3)', marginBottom: 6 }}>청크별 디코드 속도 (tok/s)</div>
      {segBars.length > 0 ? <Bars data={segBars} fmt={(v) => v.toFixed(0)} />
        : <span style={{ color: 'var(--text-3)' }}>—</span>}
    </Panel>
  )
}
