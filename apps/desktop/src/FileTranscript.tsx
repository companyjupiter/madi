import { useLayoutEffect, useMemo, useRef, useState, type CSSProperties } from 'react';
import type { FileArtwork, FileEdit, FileSnapshot, TranscriptLine } from './files';
import { MiddleText } from './MiddleText';
import { useTranscriptFollow } from './useTranscriptFollow';
import './transcript.css';

type Props = { snapshot: FileSnapshot; artwork: FileArtwork | null; language: 'ko' | 'en' | 'ja'; text: (key: string) => string; reset: () => void; edit: (edit: FileEdit) => void; copy: (id: string) => void; rename: (speaker: number) => void };
function Icon({ name, size = 16 }: { name: string; size?: number }) {
  return <span aria-hidden className="asset-icon" style={{ width: size, height: size, maskImage: `url(/assets/${name}.svg)` }} />;
}
function timecode(seconds: number, hours = false) {
  const value = Math.max(0, Math.trunc(seconds));
  return hours || value >= 3600 ? `${String(Math.trunc(value / 3600)).padStart(hours ? 2 : 1, '0')}:${String(Math.trunc(value / 60) % 60).padStart(2, '0')}:${String(value % 60).padStart(2, '0')}` : `${Math.trunc(value / 60)}:${String(value % 60).padStart(2, '0')}`;
}
function speakerColor(speaker: number) { return `var(--speaker-${((speaker % 8) + 8) % 8})`; }

// This is the connected file-view candidate. Workspace, AI tools, playback,
// confidence review and native visual parity remain separate migration gates.
export function FileTranscript({ snapshot: state, artwork, language, text, reset, edit, copy, rename }: Props) {
  const [content, setContent] = useState(true);
  const [fontSize, setFontSize] = useState(16);
  const [editing, setEditing] = useState<string | null>(null);
  const [draft, setDraft] = useState('');
  const editor = useRef<HTMLTextAreaElement>(null);
  // ContentView passes isLive only for recording/paused, never file processing.
  const follow = useTranscriptFollow(state.lines, state.generation, false, editing !== null);
  const busy = state.phase.kind === 'processing';
  const progress = state.chunksTotal > 0 ? Math.trunc(state.chunksDone / state.chunksTotal * 100) : null;
  const activity = progress === null ? text('Transcribing file') : language === 'ko' ? `파일 전사 중 · ${progress}%` : language === 'ja' ? `ファイル文字起こし中 · ${progress}%` : `Transcribing file · ${progress}%`;
  const fileStatus = busy ? progress === null ? text('Transcribing…') : language === 'ko' ? `전사 중 · ${progress}%` : language === 'ja' ? `文字起こし中 · ${progress}%` : `Transcribing · ${progress}%` : state.sizeLabel;
  const multiSpeaker = new Set(state.lines.map(line => line.speaker)).size > 1;
  const span = state.lines.length ? Math.max(0, state.lines.reduce((end, line) => Math.max(end, line.end), -Infinity) - state.lines.reduce((start, line) => Math.min(start, line.start), Infinity)) : 0;
  const name = (speaker: number) => speaker === 255 ? '미확인' : state.speakerNames[speaker] ?? (state.speakerNumbers.numbers[speaker] ? `Speaker ${state.speakerNumbers.numbers[speaker]}` : language === 'ko' ? '화자분리중…' : language === 'ja' ? '話者分離中…' : 'Separating speakers…');
  const blocks = useMemo(() => {
    const result: Array<{ id: string; speaker: number; text: string; lines: TranscriptLine[] }> = [];
    const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
    let i = 0;
    while (i < state.lines.length) {
      const speaker = state.lines[i].speaker;
      const lines: TranscriptLine[] = [];
      let count = 0;
      const island = (index: number) => state.speakerIslandAbsorption && index > 0 && index + 1 < state.lines.length && state.lines[index].speaker !== speaker && state.speakerNumbers.numbers[state.lines[index].speaker] === undefined && state.lines[index - 1].speaker === speaker && state.lines[index + 1].speaker === speaker;
      while (i < state.lines.length && (state.lines[i].speaker === speaker || island(i)) && (!lines.length || (lines.length < 8 && count < 700))) {
        const line = state.lines[i++]; lines.push(line); count += Array.from(segmenter.segment(line.text)).length;
      }
      result.push({ id: lines.at(-1)!.id, speaker, text: lines.map(line => line.text).join(' '), lines });
    }
    return result;
  }, [state.lines, state.speakerNumbers, state.speakerIslandAbsorption]);
  useLayoutEffect(() => { setEditing(null); }, [state.generation]);
  useLayoutEffect(() => {
    if (editor.current) { editor.current.style.height = 'auto'; editor.current.style.height = `${editor.current.scrollHeight}px`; }
  }, [draft, editing, fontSize]);
  function beginEdit(line: TranscriptLine) { setDraft(line.text); setEditing(line.id); }
  function saveEdit() { if (editing) edit({ type: 'line', id: editing, text: draft }); setEditing(null); }
  const speakerHeader = (speaker: number, line?: TranscriptLine) => {
    const expired = line && (state.lines.at(-1)?.end ?? 0) - line.end >= 300;
    const label = expired && speaker !== 255 && !state.speakerNames[speaker] && !state.speakerNumbers.numbers[speaker] ? `Speaker ${speaker + 1}` : name(speaker);
    return <button className="transcript-speaker" onClick={() => rename(speaker)} disabled={speaker === 255} title={text('Click to name')}><i style={{ background: speakerColor(speaker) }} />{label}</button>;
  };
  return <main className="file-workspace">
    <aside className="file-side-panel">
      <header className="file-side-header">
        <button onClick={reset} title={text('Back to start')}><Icon name="chevron-left" size={22} /></button>
        <div className="wordmark" aria-label="Madi" />
        <button title={text('Settings (⌘,)')} onClick={() => window.dispatchEvent(new CustomEvent('madi-parity-intent', { detail: 'settings' }))}><Icon name="setting" size={22} /></button>
      </header>
      <div className="file-source-card">
        <Icon name="content" size={20} />
        <MiddleText className="file-source-name">{state.fileName || text('Meeting record')}</MiddleText>
        <span className="file-source-size">{fileStatus}</span>
        <button className="file-source-close" onClick={reset} title={text('Close')}><Icon name="close" size={13} /></button>
      </div>
      <div className="file-side-rule" />
      <div className="file-total"><span>{timecode(span)}</span><b>{text('Total time')}</b></div>
    </aside>
    <section className="transcript-pane" style={{ '--transcript-font-size': `${fontSize}px` } as CSSProperties}>
      <div className="transcript-toolbar">
        <button className="font-smaller" title={text('Smaller text')} onClick={() => setFontSize(value => Math.max(12, value - 2))}>A</button>
        <span className="font-size">{fontSize}</span>
        <button className="font-larger" title={text('Larger text')} onClick={() => setFontSize(value => Math.min(34, value + 2))}>A</button>
        <div className="transcript-mode" role="group" aria-label={text('Content: clean transcript · Detail: timecodes, confidence, overlap')}>
          <button aria-pressed={content} onClick={() => setContent(true)}>{text('Content')}</button>
          <button aria-pressed={!content} onClick={() => setContent(false)}>{text('Detail')}</button>
        </div>
      </div>
      <div className={`transcript-reader${state.lines.length ? ' has-lines' : ''}${follow.badge.scrolled ? ' scrolled' : ''}`}>
      <div className="transcript-scroll" ref={follow.viewport}>
        <div className={`transcript-scroll-content${state.lines.length ? '' : ' empty-layout'}`} ref={follow.contents}>
        {state.lines.length === 0 ? state.phase.kind === 'error' ? <div className="transcript-error" role="alert">{state.phase.message}</div> : busy ? <div className="transcript-status">{text('Your transcript will appear here shortly.')}<span className="loading-dots" aria-hidden>•••</span></div> : <div className="transcript-empty"><strong>{text('Nothing was transcribed')}</strong><span>{text('No speech was recognized. Go back with ‹ and try again.')}</span></div> : <>
          {content ? <div className="transcript-blocks">{blocks.map(block => <article key={`block-${block.id}`} className="transcript-block">
            {multiSpeaker && speakerHeader(block.speaker)}
            <p className="transcript-body" onDoubleClick={() => setContent(false)}>{block.text}</p>
            {[...new Set(block.lines.flatMap(line => Object.keys(line.translations)))].sort().map(lang => <p className="transcript-translation" key={lang}>{block.lines.map(line => line.translations[lang]).filter(Boolean).join(' ')}</p>)}
          </article>)}</div> : <div className="transcript-details">{state.lines.map((line, index) => {
            const previous = state.lines[index - 1];
            const continuation = previous?.speaker === line.speaker && line.start - previous.end < 2.5;
            return <article key={line.id} className={`transcript-row${continuation ? ' continuation' : ''}`}>
              <header className="transcript-row-header">
                {!continuation && <>{speakerHeader(line.speaker, line)}<time>{timecode(line.start, true)}</time>{line.editedText !== null && <span className="transcript-edited">{text('Edited')}</span>}</>}
                <div className="transcript-actions">
                  <button title={text('Copy this line')} onClick={() => copy(line.id)}><Icon name="squares" /></button>
                  <button title={text('Edit this line')} onClick={() => beginEdit(line)}><Icon name="pen" /></button>
                </div>
              </header>
              {editing === line.id ? <><textarea autoFocus ref={editor} value={draft} onChange={event => setDraft(event.target.value)} onKeyDown={event => {
                if (event.key === 'Escape') { event.preventDefault(); setEditing(null); }
                if (event.key === 'Enter' && event.metaKey) { event.preventDefault(); saveEdit(); }
              }} /><div className="transcript-edit-actions"><button onClick={saveEdit}>{text('Save')}</button><button onClick={() => setEditing(null)}>{text('Cancel')}</button></div></> : <p className="transcript-body" onDoubleClick={() => beginEdit(line)}>{line.text}</p>}
              {Object.entries(line.translations).map(([lang, value]) => <p className="transcript-translation" key={lang}>{value}</p>)}
              {Object.entries(line.staleTranslations).filter(([lang]) => !line.translations[lang]).map(([lang, value]) => <p className="transcript-translation stale" key={lang}>{value}</p>)}
            </article>;
          })}</div>}
          {busy && <div className="transcript-status transcript-tail-status">{activity}<span className="loading-dots" aria-hidden>•••</span></div>}
          {state.phase.kind === 'error' && <div className="transcript-error" role="alert">{state.phase.message}</div>}
          <div className="transcript-tail-clearance" />
        </>}
        </div>
      </div>
      <button className={`transcript-follow-pill${!follow.badge.atBottom && follow.badge.unseen > 0 ? ' shown' : ''}`}
        tabIndex={!follow.badge.atBottom && follow.badge.unseen > 0 ? 0 : -1}
        aria-hidden={follow.badge.atBottom || follow.badge.unseen === 0} onClick={follow.jumpToTail}>
        {artwork && <span aria-hidden className="asset-icon" style={{ width: artwork.follow.width, height: artwork.follow.height, maskImage: `url(${artwork.follow.dataUrl})` }} />}
        {language === 'ko' ? `새 전사 ${follow.badge.unseen}` : language === 'ja' ? `新規 ${follow.badge.unseen}` : `${follow.badge.unseen} new`}
      </button>
      </div>
    </section>
  </main>;
}
