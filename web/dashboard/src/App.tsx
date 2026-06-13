import { useState } from 'react'
import { useEvents } from './useEvents'
import { kpis } from './metrics'
import { TopBar } from './components/TopBar'
import { KpiRow } from './components/KpiRow'
import { TranscriptPanel, SpeakerPanel, QualityPanel, PerfPanel } from './components/panels'

export default function App() {
  const [fixture, setFixture] = useState('devops_ko')
  // 'instant' = fixture all at once; 'live' = SSE from the bridge (real engine).
  const [mode, setMode] = useState<'instant' | 'live'>('instant')
  const { state, loading } = useEvents(fixture, mode)
  const k = kpis(state)

  return (
    <div style={{ height: '100%', display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
      <TopBar state={state} fixture={fixture} onFixture={setFixture}
        live={mode === 'live' && !state.ended}
        mode={mode} onMode={setMode} />
      <KpiRow k={k} />
      <main style={{
        flex: 1, minHeight: 0, padding: '0 18px 18px', display: 'grid', gap: 12,
        gridTemplateColumns: '1.5fr 1fr',
        gridTemplateRows: '1.1fr 0.9fr 0.9fr',
        gridTemplateAreas: `'tx spk' 'tx ql' 'pf ql'`,
      }}>
        <TranscriptPanel s={state} />
        <SpeakerPanel s={state} />
        <QualityPanel s={state} />
        <PerfPanel s={state} />
      </main>
      {loading && <div style={{ position: 'fixed', inset: 0, display: 'grid', placeItems: 'center',
        background: 'rgba(14,18,23,.6)', color: 'var(--text-2)' }}>불러오는 중…</div>}
    </div>
  )
}
