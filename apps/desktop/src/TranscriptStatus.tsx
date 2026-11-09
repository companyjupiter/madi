import { useEffect, useState } from 'react';
import type { TranscriptStatus as Presentation } from './files';
import { liveLabel } from './LiveControls';

// The shipping dots start dim, then select one dot every 320 ms. Only opacity
// interpolates for 250 ms; glyph size/spacing and the text layout stay fixed.
export function LoadingDots() {
  const [phase, setPhase] = useState(-1);
  useEffect(() => { const timer = window.setInterval(() => setPhase(old => (old + 1) % 3), 320); return () => clearInterval(timer); }, []);
  return <span className="loading-dots" aria-hidden>{[0, 1, 2].map(i => <i key={i} style={{ opacity: phase === i ? 1 : .35 }} />)}</span>;
}
export function TranscriptStatus({ value, language, generation }: { value: Presentation; language: 'ko' | 'en' | 'ja'; generation: number }) {
  const [expanded, setExpanded] = useState(false);
  useEffect(() => setExpanded(false), [generation]);
  const l = (ko: string, en: string) => liveLabel(language, ko, en);
  if (value.warning === null && value.activity === null) return null;
  return <div className="transcript-status-area">
    {value.warning !== null && <>
      <div className="transcript-warning">
        <img className="status-warning-icon" src="/assets/exclamation-circle.svg" alt="" />
        <span className="status-gradient">{value.warning}</span>
        {value.gapTimes.length === 0 ? <LoadingDots /> : <button aria-expanded={expanded} title={expanded ? l('접기', 'Collapse') : l('누락 의심 구간 보기', 'Show suspected gaps')} onClick={() => setExpanded(!expanded)}><span aria-hidden className={`asset-icon gap-chevron${expanded ? ' expanded' : ''}`} /></button>}
      </div>
      {expanded && value.gapTimes.length > 0 && <div className="transcript-gap-box">
        <p>{l('소리는 있었지만 전사가 비어 재시도도 실패한 구간이에요', 'There was sound but transcription came up empty, and a retry also failed')}</p>
        {value.gapTimes.map((time, index) => <div className="transcript-gap" key={index}><i /><time>{time}</time><span>{l('근처', 'area')}</span></div>)}
      </div>}
    </>}
    {value.activity !== null && <div className="transcript-status"><span>{value.activity}</span><LoadingDots /></div>}
  </div>;
}
