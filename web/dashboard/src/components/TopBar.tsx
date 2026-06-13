import { SessionState, langLabel } from '../types'

const FIXTURES = [
  { id: 'jfk3', label: 'JFK (영어·1화자)' },
  { id: 'devops_ko', label: '데브옵스 Q&A (한국어·2화자)' },
]

export function TopBar({ state, fixture, onFixture, live }:
  { state: SessionState; fixture: string; onFixture: (f: string) => void; live: boolean }) {
  return (
    <header style={{ display: 'flex', alignItems: 'center', gap: 16, padding: '12px 18px',
      borderBottom: '1px solid var(--border)', background: 'var(--panel)' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <div style={{ width: 10, height: 10, borderRadius: 3, background: 'var(--accent)' }} />
        <strong style={{ fontSize: 15, letterSpacing: '-0.02em' }}>Sovereign</strong>
        <span style={{ color: 'var(--text-3)', fontSize: 12 }}>실시간 전사 대시보드</span>
      </div>

      <span className={`badge ${live ? 'live' : 'ok'}`}>
        {live ? '● LIVE' : state.ended ? '완료' : '대기'}
      </span>

      <div style={{ display: 'flex', gap: 18, marginLeft: 8, color: 'var(--text-2)', fontSize: 12 }}>
        <span>모델 <b style={{ color: 'var(--text)' }}>{state.meta?.model ?? '—'}</b></span>
        <span>언어 <b style={{ color: 'var(--text)' }}>{langLabel(state.meta?.lang)}</b></span>
        <span>샘플레이트 <b className="mono" style={{ color: 'var(--text)' }}>{state.meta?.sr ?? '—'}Hz</b></span>
      </div>

      <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 8 }}>
        <span style={{ color: 'var(--text-3)', fontSize: 12 }}>데모 소스</span>
        <select value={fixture} onChange={(e) => onFixture(e.target.value)}
          style={{ background: 'var(--panel-2)', color: 'var(--text)', border: '1px solid var(--border)',
            borderRadius: 8, padding: '6px 10px', fontSize: 12 }}>
          {FIXTURES.map((f) => <option key={f.id} value={f.id}>{f.label}</option>)}
        </select>
      </div>
    </header>
  )
}
