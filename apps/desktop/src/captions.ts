import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { getCurrentWebviewWindow } from '@tauri-apps/api/webviewWindow';
import { browserFixture } from './bridge';
import type { SessionSettings } from './settings';
export interface CaptionSnapshot {
  revision: number; enabled: boolean; audience: 'staff' | 'patient'; uiLanguage: 'ko' | 'en' | 'ja';
  settings: SessionSettings['caption'];
  artwork: Record<string, { dataUrl: string; width: number; height: number }> | null;
  projection: {
    language: string | null; header: string; status: 'live' | 'translating' | 'waiting'; statusText: string; waitingText: string;
    speakerLabel: string | null; preview: string | null; meter: boolean[];
    caption: null | { translation: string; original: string; provisional: boolean; speaker: number | null; margin: number; age: number };
  };
}
interface Status { revision: number; enabled: boolean; failed?: boolean }
export function useCaptionControl() {
  const [status, setStatus] = useState<Status>({ revision: 0, enabled: false });
  const [failed, setFailed] = useState(false);
  const pending = useRef(Promise.resolve());
  const receive = (next: Status) => setStatus(old => old.revision > next.revision ? old : next);
  useEffect(() => {
    if (browserFixture) return;
    let active = true; let unlisten: (() => void) | undefined;
    void getCurrentWebviewWindow().listen<Status>('caption-status-changed', event => { if (active) receive(event.payload); }).then(async cleanup => {
      if (!active) { cleanup(); return; } unlisten = cleanup;
      const next = await invoke<Status>('caption_status'); if (active) receive(next);
    }).catch(() => { if (active) setFailed(true); });
    return () => { active = false; unlisten?.(); };
  }, []);
  const toggle = () => {
    if (browserFixture) return;
    pending.current = pending.current.then(async () => { receive(await invoke<Status>('caption_toggle')); setFailed(false); }).catch(() => setFailed(true));
  };
  return { enabled: status.enabled, failed: failed || status.failed === true, toggle };
}
