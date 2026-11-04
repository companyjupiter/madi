import { useEffect, useRef, useState, type ReactNode } from 'react';
import { audioInputs, type InputDevices } from './bridge';
import type { FileArtwork, FileSnapshot, LiveControl } from './files';
import { MiddleText } from './MiddleText';

type Language = 'ko' | 'en' | 'ja';
export function liveLabel(language: Language, ko: string, en: string, ja = en) { return language === 'ko' ? ko : language === 'ja' ? ja : en; }
export function NativeSymbol({ artwork, name, className = '' }: { artwork: FileArtwork | null; name: keyof FileArtwork; className?: string }) {
  const symbol = artwork?.[name];
  if (!symbol && (name === 'caption' || name === 'captionOn')) return <svg aria-hidden width="12" height="12" viewBox="0 0 16 16" className={className} fill="none" stroke="currentColor" strokeWidth="1.2"><path d="M2 2h12v9H7l-3 3v-3H2zM4 5h8M4 8h6" />{name === 'captionOn' && <path d="M2 2h12v9H7l-3 3v-3H2z" fill="currentColor" fillOpacity="0.2" />}</svg>;
  return symbol ? <span aria-hidden className={`asset-icon ${className}`} style={{ width: symbol.width, height: symbol.height, maskImage: `url(${symbol.dataUrl})` }} /> : null;
}
export function phaseLabel(state: FileSnapshot, language: Language) {
  const l = (ko: string, en: string, ja = en) => liveLabel(language, ko, en, ja);
  switch (state.phase.kind) {
    case 'engineStarting': return l('모델 로딩…', 'Loading model…');
    case 'ready': return state.live?.source === 'mic' ? l('마이크 연결 중…', 'Connecting microphone…', 'マイクに接続中…') : l('시스템 오디오 연결 중…', 'Connecting system audio…', 'システムオーディオに接続中…');
    case 'recording': return l('녹음 중', 'Recording');
    case 'paused': return l('일시정지', 'Paused');
    case 'flushing': return l('마무리…', 'Wrapping up…');
    case 'countingDown': return l(`${state.phase.remaining}초 후 시작…`, `Starting in ${state.phase.remaining}s…`, `${state.phase.remaining}秒後に開始…`);
    default: return '';
  }
}
export function LiveControls({ state, artwork, language, control, reset }: { state: FileSnapshot; artwork: FileArtwork | null; language: Language; control: (command: LiveControl) => void; reset: () => void }) {
  const l = (ko: string, en: string, ja = en) => liveLabel(language, ko, en, ja);
  const active = state.phase.kind === 'recording' || state.phase.kind === 'paused';
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if (event.repeat || event.isComposing || event.altKey || event.ctrlKey) return;
      if (state.phase.kind === 'countingDown' && event.key === 'Escape') { event.preventDefault(); control({ type: 'cancelCountdown' }); }
      if (active && event.metaKey) {
        if (event.key.toLowerCase() === 'p') { event.preventDefault(); control({ type: state.phase.kind === 'paused' ? 'resume' : 'pause' }); }
        if (event.key.toLowerCase() === 'r') { event.preventDefault(); control({ type: 'stop' }); }
      }
    };
    window.addEventListener('keydown', key); return () => window.removeEventListener('keydown', key);
  }, [state.phase.kind, active, control]);
  const card = (label: string, glyph: ReactNode, action: () => void) => <button className="live-control" onClick={action}><span className="live-glyph">{glyph}</span><span>{label}</span></button>;
  return <div className="live-controls">
    {active ? <>
      {state.phase.kind === 'paused' ? card(l('재개', 'Resume'), <NativeSymbol artwork={artwork} name="play" />, () => control({ type: 'resume' })) : card(l('일시 정지', 'Pause'), <span className="pause-glyph"><i /><i /></span>, () => control({ type: 'pause' }))}
      {card(l('정지', 'Stop'), <span className="stop-glyph" />, () => control({ type: 'stop' }))}
    </> : state.phase.kind === 'countingDown' ? card(l(`시작까지 ${state.phase.remaining} · 취소`, `Starts in ${state.phase.remaining} · cancel`, `開始まで ${state.phase.remaining} · キャンセル`), <NativeSymbol artwork={artwork} name="cancel" />, () => control({ type: 'cancelCountdown' }))
      : ['engineStarting', 'ready', 'flushing', 'processing'].includes(state.phase.kind) ? <div className="live-control live-busy"><span className="native-spinner" aria-hidden>{Array.from({ length: 12 }, (_, i) => <i key={i} style={{ transform: `rotate(${i * 30}deg) translateY(-5px)`, opacity: (i + 1) / 12 }} />)}</span>{phaseLabel(state, language)}</div>
      : card(l('새 기록 시작', 'New recording'), <NativeSymbol artwork={artwork} name="plus" />, reset)}
  </div>;
}
export function LiveMic({ state, artwork, language, control }: { state: FileSnapshot; artwork: FileArtwork | null; language: Language; control: (command: LiveControl) => void }) {
  const [inputs, setInputs] = useState<InputDevices>({ supported: false, devices: [], defaultInputId: null });
  const [open, setOpen] = useState(false);
  const [error, setError] = useState('');
  const root = useRef<HTMLDivElement>(null);
  const visible = Boolean(state.live && state.live.source !== 'system' && ['recording', 'paused'].includes(state.phase.kind));
  useEffect(() => {
    if (!visible) { setOpen(false); return; }
    let active = true;
    const refresh = () => { void audioInputs().then(value => { if (active) setInputs(value); }).catch(reason => { if (active) setError(String(reason)); }); };
    refresh(); window.addEventListener('focus', refresh);
    return () => { active = false; window.removeEventListener('focus', refresh); };
  }, [visible, open]);
  useEffect(() => {
    if (!open) return;
    const click = (event: PointerEvent) => { if (!root.current?.contains(event.target as Node)) setOpen(false); };
    const key = (event: KeyboardEvent) => { if (event.key === 'Escape') setOpen(false); };
    document.addEventListener('pointerdown', click); document.addEventListener('keydown', key);
    return () => { document.removeEventListener('pointerdown', click); document.removeEventListener('keydown', key); };
  }, [open]);
  if (!visible || !state.live) return null;
  const l = (ko: string, en: string, ja = en) => liveLabel(language, ko, en, ja);
  const label = inputs.devices.find(d => d.id === state.live!.inputDevice)?.name ?? inputs.devices.find(d => d.id === inputs.defaultInputId)?.name ?? l('시스템 기본', 'System default');
  const db = 20 * Math.log10(Math.max(state.live.meter / 3, 1e-5));
  const hint = db < -35 ? l('작음 · 마이크를 가까이', 'low · move closer', '小さい · マイクを近づけて') : db < -22 ? l('보통', 'ok', '普通') : l('좋음', 'good', '良好');
  const select = (value: string | null) => { control({ type: 'inputDevice', value }); setOpen(false); };
  return <div className="live-mic" ref={root}>
    <div className="live-mic-row"><b>{l('입력 마이크', 'Input mic')}</b><button aria-expanded={open} onClick={() => setOpen(!open)} title={l('녹음 중에도 입력 마이크를 바꿀 수 있어요', 'Swap the input mic even while recording')}><MiddleText>{label}</MiddleText><NativeSymbol artwork={artwork} name="micChevron" className={open ? 'up' : ''} /></button></div>
    {open && <div className="dropdown live-mic-dropdown"><button className="option" onClick={() => select(null)}>{l('시스템 기본', 'System default')}{!state.live.inputDevice && <span>✓</span>}</button>{inputs.devices.map(device => <button className="option" key={device.id} onClick={() => select(device.id)}>{device.name}{state.live!.inputDevice === device.id && <span>✓</span>}</button>)}</div>}
    <div className="live-level"><span>{l('입력 레벨', 'Input level', '入力レベル')}</span><span className={db < -35 ? 'low' : ''}>{db.toFixed(0)} dB · {hint}</span></div>
    {error && <span role="alert">{error}</span>}
  </div>;
}
