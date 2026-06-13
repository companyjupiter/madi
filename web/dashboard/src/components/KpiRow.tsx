import { Kpis } from '../metrics'

// Korea-friendly: a dense row of KPI tiles up top — operators scan the headline
// numbers at a glance before drilling into panels.
function Tile({ label, value, unit, tone, hint }:
  { label: string; value: string; unit?: string; tone?: 'good' | 'warn' | 'bad'; hint?: string }) {
  const color = tone ? `var(--${tone})` : 'var(--text)'
  return (
    <div style={{ background: 'var(--panel)', border: '1px solid var(--border)', borderRadius: 10,
      padding: '10px 14px', minWidth: 0, display: 'flex', flexDirection: 'column', gap: 3 }}>
      <span style={{ fontSize: 11, color: 'var(--text-3)', whiteSpace: 'nowrap' }}>{label}</span>
      <span className="mono" style={{ fontSize: 22, fontWeight: 700, color, lineHeight: 1 }}>
        {value}{unit && <span style={{ fontSize: 12, color: 'var(--text-3)', fontWeight: 500 }}> {unit}</span>}
      </span>
      {hint && <span style={{ fontSize: 10, color: 'var(--text-3)' }}>{hint}</span>}
    </div>
  )
}

const fmtDur = (s: number) => {
  const m = Math.floor(s / 60), ss = Math.floor(s % 60)
  return `${m}:${String(ss).padStart(2, '0')}`
}

export function KpiRow({ k }: { k: Kpis }) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(8, 1fr)', gap: 12, padding: '12px 18px' }}>
      <Tile label="녹음 길이" value={fmtDur(k.durationS)} hint="분:초" />
      <Tile label="단어 수" value={k.words.toLocaleString()} />
      <Tile label="화자 수" value={String(k.speakers)} hint="명" />
      <Tile label="평균 신뢰도" value={(k.avgConf * 100).toFixed(1)} unit="%"
        tone={k.avgConf >= 0.85 ? 'good' : k.avgConf >= 0.7 ? 'warn' : 'bad'} />
      <Tile label="저신뢰 단어" value={k.lowConfPct.toFixed(1)} unit="%"
        tone={k.lowConfPct <= 8 ? 'good' : k.lowConfPct <= 20 ? 'warn' : 'bad'} hint="< 55%" />
      <Tile label="디코드 속도" value={k.tokS.toFixed(0)} unit="tok/s" tone="good" />
      <Tile label="실시간 배율" value={k.rtf.toFixed(2)} unit="× RTF"
        tone={k.rtf < 0.5 ? 'good' : k.rtf < 1 ? 'warn' : 'bad'} hint="낮을수록 빠름" />
      <Tile label="재디코드" value={String(k.fallbacks)} hint={`드롭 ${k.dropped}`}
        tone={k.fallbacks === 0 ? 'good' : 'warn'} />
    </div>
  )
}
