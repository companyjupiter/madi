import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { getCurrentWebviewWindow } from '@tauri-apps/api/webviewWindow';
import type { CaptionSnapshot } from './captions';
import './caption.css';

function Symbol({ state, name }: { state: CaptionSnapshot; name: 'caption' | 'close' | 'mic' }) {
  const image = state.artwork?.[name];
  if (image) return <span aria-hidden className="caption-symbol" style={{ width: image.width, height: image.height, maskImage: `url(${image.dataUrl})` }} />;
  return <svg aria-hidden viewBox="0 0 16 16" className={`caption-fallback caption-${name}`}><path d={name === 'caption' ? 'M2 2h12v9H7l-3 3v-3H2zM4 5h8M4 8h6' : name === 'close' ? 'M3 3l10 10M13 3L3 13' : 'M6 6V3a2 2 0 0 1 4 0v3a2 2 0 0 1-4 0ZM4 6a4 4 0 0 0 8 0M8 10v4M5 14h6'} /></svg>;
}
function Translation({ text, fontSize, minScale, lines }: { text: string; fontSize: number; minScale: number; lines: number }) {
  const measure = useRef<HTMLParagraphElement>(null);
  const [scale, setScale] = useState(1);
  useLayoutEffect(() => {
    const element = measure.current; if (!element) return;
    const fit = () => {
      const range = document.createRange(); range.selectNodeContents(element);
      const fits = (value: number) => {
        element.style.fontSize = `${fontSize * value}px`;
        return new Set([...range.getClientRects()].filter(r => r.width > 0).map(r => Math.round(r.top * 2))).size <= lines;
      };
      let lo = Math.max(0.5, Math.min(1, minScale)); let hi = 1;
      if (fits(1)) lo = 1;
      else if (fits(lo)) for (let i = 0; i < 8; i++) { const mid = (lo + hi) / 2; if (fits(mid)) lo = mid; else hi = mid; }
      element.style.fontSize = `${fontSize}px`; setScale(lo);
    };
    fit(); const observer = new ResizeObserver(fit); observer.observe(element);
    return () => observer.disconnect();
  }, [text, fontSize, minScale, lines]);
  return <div className="caption-translation-wrap" data-tauri-drag-region>
    <p className="caption-translation" data-tauri-drag-region style={{ fontSize: fontSize * scale, WebkitLineClamp: lines }}>{text}</p>
    <p ref={measure} className="caption-measure" aria-hidden style={{ fontSize }}>{text}</p>
  </div>;
}
export function CaptionContent({ state, close }: { state: CaptionSnapshot; close: () => void }) {
  const p = state.projection; const caption = p.caption; const patient = state.audience === 'patient';
  const font = patient ? state.settings.patientFontSize : state.settings.staffFontSize;
  return <div className={`caption-frame${patient ? ' patient' : ''}`} data-tauri-drag-region style={{ '--caption-font': `${font}px` } as CSSProperties}>
    <section className="caption-card" data-tauri-drag-region>
      <header className="caption-header" data-tauri-drag-region>
        <Symbol state={state} name="caption" /><span data-tauri-drag-region>{p.header}</span>
        {p.status !== 'waiting' && <small data-tauri-drag-region>{p.statusText}</small>}
        {!patient && <button onClick={close} aria-label={state.uiLanguage === 'ko' ? '닫기' : state.uiLanguage === 'ja' ? '閉じる' : 'Close'}><Symbol state={state} name="close" /></button>}
      </header>
      {caption ? <>
        {p.speakerLabel !== null && <div className="caption-speaker" data-tauri-drag-region><i style={{ background: `var(--speaker-${(((caption.speaker ?? 0) % 8) + 8) % 8})` }} /><span data-tauri-drag-region>{p.speakerLabel}</span></div>}
        <div className={caption.provisional ? 'caption-provisional' : ''}><Translation text={caption.translation} fontSize={font} minScale={state.settings.minScaleFactor} lines={patient ? 3 : 2} /></div>
        <p className="caption-original" data-tauri-drag-region>{caption.original}</p>
      </> : p.preview !== null ? <p className="caption-preview" data-tauri-drag-region>{p.preview}</p> : <div className="caption-waiting" data-tauri-drag-region>
        <p data-tauri-drag-region>{p.waitingText}</p>
        <div className="caption-meter" data-tauri-drag-region><Symbol state={state} name="mic" />{p.meter.map((on, i) => <i key={i} style={{ height: 6 + i * 3, opacity: on ? 0.7 : 0.15 }} />)}</div>
      </div>}
    </section>
  </div>;
}
export function CaptionWindow() {
  const [state, setState] = useState<CaptionSnapshot | null>(null);
  const root = useRef<HTMLDivElement>(null); const lastHeight = useRef(0);
  useEffect(() => {
    let active = true; let unlisten: (() => void) | undefined;
    const receive = (next: CaptionSnapshot) => { if (active) setState(old => old && old.revision > next.revision ? old : next); };
    void getCurrentWebviewWindow().listen<CaptionSnapshot>('caption-changed', event => receive(event.payload)).then(async cleanup => {
      if (!active) { cleanup(); return; } unlisten = cleanup; receive(await invoke<CaptionSnapshot>('caption_snapshot'));
    }).catch(error => console.error('caption snapshot', error));
    return () => { active = false; unlisten?.(); };
  }, []);
  useLayoutEffect(() => {
    const element = root.current; if (!element || !state) return;
    document.documentElement.lang = state.uiLanguage;
    const size = () => {
      const height = Math.max(80, Math.min(600, Math.ceil(element.getBoundingClientRect().height)));
      if (height !== lastHeight.current) { lastHeight.current = height; void invoke('caption_resize', { height }).catch(error => console.error('caption size', error)); }
    };
    size(); const observer = new ResizeObserver(size); observer.observe(element); return () => observer.disconnect();
  }, [state?.uiLanguage, state !== null]);
  return <div ref={root}>{state && <CaptionContent state={state} close={() => { void invoke('caption_close').catch(error => console.error('caption close', error)); }} />}</div>;
}
