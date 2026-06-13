// charts.tsx — dependency-free SVG charts (no chart-lib lock-in; a UI/UX
// engineer can restyle or swap these freely). All take plain data + colors.
import { CSSProperties } from 'react'

export const spkColor = (id: number) => `var(--spk-${((id % 8) + 8) % 8})`

/** Donut for talk-time share. data: [{label, value, color}]. */
export function Donut({ data, size = 120, thickness = 18 }:
  { data: { label: string; value: number; color: string }[]; size?: number; thickness?: number }) {
  const total = data.reduce((a, d) => a + d.value, 0) || 1
  const r = (size - thickness) / 2
  const c = size / 2
  const circ = 2 * Math.PI * r
  let acc = 0
  return (
    <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
      <circle cx={c} cy={c} r={r} fill="none" stroke="var(--panel-2)" strokeWidth={thickness} />
      {data.map((d, i) => {
        const frac = d.value / total
        const dash = `${frac * circ} ${circ}`
        const off = -acc * circ
        acc += frac
        return (
          <circle key={i} cx={c} cy={c} r={r} fill="none" stroke={d.color}
            strokeWidth={thickness} strokeDasharray={dash} strokeDashoffset={off}
            transform={`rotate(-90 ${c} ${c})`} />
        )
      })}
      <text x={c} y={c - 2} textAnchor="middle" fontSize="20" fontWeight="700" fill="var(--text)">{data.length}</text>
      <text x={c} y={c + 16} textAnchor="middle" fontSize="10" fill="var(--text-3)">화자</text>
    </svg>
  )
}

/** Horizontal bar list. */
export function Bars({ data, max, fmt = (v) => v.toFixed(0) }:
  { data: { label: string; value: number; color: string }[]; max?: number; fmt?: (v: number) => string }) {
  const m = max ?? Math.max(1, ...data.map((d) => d.value))
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      {data.map((d, i) => (
        <div key={i} style={{ display: 'grid', gridTemplateColumns: '64px 1fr 48px', alignItems: 'center', gap: 8 }}>
          <span style={{ color: 'var(--text-2)', fontSize: 12 }}>{d.label}</span>
          <div style={{ background: 'var(--panel-2)', borderRadius: 4, height: 14, overflow: 'hidden' }}>
            <div style={{ width: `${(100 * d.value) / m}%`, height: '100%', background: d.color, borderRadius: 4 }} />
          </div>
          <span className="mono" style={{ textAlign: 'right', color: 'var(--text-2)', fontSize: 12 }}>{fmt(d.value)}</span>
        </div>
      ))}
    </div>
  )
}

/** Histogram (bars from a number[]). Highlights low-confidence bins amber. */
export function Histogram({ bins, lowCutBin }: { bins: number[]; lowCutBin: number }) {
  const max = Math.max(1, ...bins)
  return (
    <div style={{ display: 'flex', alignItems: 'flex-end', gap: 3, height: 90 }}>
      {bins.map((v, i) => (
        <div key={i} title={`${(i * 10)}–${(i * 10 + 10)}%: ${v}`}
          style={{ flex: 1, height: `${(100 * v) / max}%`, minHeight: v ? 2 : 0,
            background: i < lowCutBin ? 'var(--low-conf)' : 'var(--accent)',
            borderRadius: '3px 3px 0 0', transition: 'height .2s' }} />
      ))}
    </div>
  )
}

/** Speaker timeline: a horizontal track per speaker, blocks at their spk_segs. */
export function Timeline({ segs, duration, speakers }:
  { segs: { t0: number; spk: number }[]; duration: number; speakers: number[] }) {
  const sorted = [...segs].sort((a, b) => a.t0 - b.t0)
  const rowH = 18, pad = 2
  const H = speakers.length * (rowH + pad)
  const pct = (t: number) => (duration > 0 ? (100 * t) / duration : 0)
  return (
    <svg width="100%" height={H} viewBox={`0 0 100 ${H}`} preserveAspectRatio="none" style={{ display: 'block' }}>
      {speakers.map((sp, row) => {
        const y = row * (rowH + pad)
        return (
          <g key={sp}>
            <rect x={0} y={y} width={100} height={rowH} fill="var(--panel-2)" rx={1} />
            {sorted.map((s, i) => {
              if (s.spk !== sp) return null
              const end = i + 1 < sorted.length ? sorted[i + 1].t0 : duration
              const x = pct(s.t0), w = Math.max(0.4, pct(end) - pct(s.t0))
              return <rect key={i} x={x} y={y} width={w} height={rowH} fill={spkColor(sp)} rx={1} />
            })}
          </g>
        )
      })}
    </svg>
  )
}

export const labelStyle: CSSProperties = { fontSize: 11, color: 'var(--text-3)' }
