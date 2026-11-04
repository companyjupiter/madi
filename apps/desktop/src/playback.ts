import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { getCurrentWebviewWindow } from '@tauri-apps/api/webviewWindow';
import { browserFixture } from './bridge';
import type { TranscriptLine, ReviewWord } from './files';

interface Review { isListening: boolean; index: number; count: number; current: ReviewWord | null; scrollTick: number; scrollTarget: string | null; barIndex: number }
const emptyReview: Review = { isListening: false, index: 0, count: 0, current: null, scrollTick: 0, scrollTarget: null, barIndex: 0 };
interface Status { revision: number; generation: number; playingLine: string | null; review: Review }
export function useLinePlayback(generation: number) {
  const [status, setStatus] = useState<Status>({ revision: 0, generation: 0, playingLine: null, review: emptyReview });
  const pending = useRef(Promise.resolve());
  const receive = (next: Status) => setStatus(old => old.revision > next.revision ? old : next);
  useEffect(() => {
    if (browserFixture) return;
    let active = true; let unlisten: (() => void) | undefined;
    void getCurrentWebviewWindow().listen<Status>('playback-changed', event => { if (active) receive(event.payload); }).then(async cleanup => {
      if (!active) { cleanup(); return; } unlisten = cleanup;
      const next = await invoke<Status>('playback_snapshot'); if (active) receive(next);
    }).catch(error => console.error('line playback state:', error));
    return () => { active = false; unlisten?.(); };
  }, []);
  const toggle = (line: TranscriptLine) => {
    if (browserFixture) return;
    // Keep rapid A/B/A and tap-again commands in the user's order. Each queued
    // operation retains its displayed span and session generation.
    const request = { generation, id: line.id, from: line.start, to: line.end };
    pending.current = pending.current.then(() => invoke<void>('playback_toggle', request)).catch(error => console.error('line playback:', error));
  };
  const reviewCommand = (command: { type: 'visibility'; visible: boolean } | { type: 'toggle' | 'stop' } | { type: 'jump'; delta: number }) => {
    if (browserFixture) return;
    const request = { generation, command };
    pending.current = pending.current.then(() => invoke<void>('review_command', request)).catch(error => console.error('listen review:', error));
  };
  return { playingLine: status.generation === generation ? status.playingLine : null,
    review: status.generation === generation ? status.review : emptyReview, reviewCommand, toggle };
}
