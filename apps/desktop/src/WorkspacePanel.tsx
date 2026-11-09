import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import type { FileArtwork } from './files';
import type { ExportFormat, WorkspaceSnapshot } from './workspace';
import { MiddleText } from './MiddleText';
import './workspace.css';
type Language = 'ko' | 'en' | 'ja';
type Props = {
  state: WorkspaceSnapshot; artwork: FileArtwork | null; language: Language; text: (key: string) => string;
  hasLines: boolean; open: (id: string) => void; setAutoSave: (value: boolean) => void;
  chooseFolder: () => void; showStats: (visible: boolean) => void; exportFile: (format: ExportFormat) => void;
};
function Symbol({ artwork, name }: { artwork: FileArtwork | null; name: 'folder' | 'export' }) {
  const symbol = artwork?.[name];
  return symbol ? <span aria-hidden className="asset-icon" style={{ width: symbol.width, height: symbol.height, maskImage: `url(${symbol.dataUrl})` }} /> : null;
}
function hoursMinutes(seconds: number, language: Language) {
  const minutes = Math.round(seconds / 60);
  const hours = Math.trunc(minutes / 60);
  return language === 'ko' ? hours > 0 ? `${hours}시간 ${minutes % 60}분` : `${minutes}분`
    : language === 'ja' ? hours > 0 ? `${hours}時間 ${minutes % 60}分` : `${minutes}分`
    : hours > 0 ? `${hours}h ${minutes % 60}m` : `${minutes}m`;
}
function StatValue({ value }: { value: string }) {
  const container = useRef<HTMLDivElement>(null);
  const label = useRef<HTMLSpanElement>(null);
  useLayoutEffect(() => {
    const fit = () => {
      if (!container.current || !label.current) return;
      label.current.style.fontSize = '18px';
      const width = label.current.getBoundingClientRect().width;
      label.current.style.fontSize = `${18 * Math.max(.55, Math.min(1, container.current.clientWidth / Math.max(1, width)))}px`;
    };
    fit(); const observer = new ResizeObserver(fit);
    if (container.current) observer.observe(container.current);
    return () => observer.disconnect();
  }, [value]);
  return <div ref={container} className="workspace-stat-value"><span ref={label}>{value}</span></div>;
}
function Stats({ state, language, text }: Pick<Props, 'state' | 'language' | 'text'>) {
  const stats = state.stats;
  if (!stats.meetingCount) return <div className="workspace-stats-empty"><strong>{text('No saved meetings')}</strong><span>{text('Activity stats build up as you save meetings')}</span></div>;
  const values = [[String(stats.meetingCount), 'Meetings'], [hoursMinutes(stats.totalSeconds, language), 'Total time'], [hoursMinutes(stats.avgSeconds, language), 'Avg length'], [state.totalWordsLabel, 'Total words']];
  const max = Math.max(1, ...stats.weeklyTrend);
  const weeks = stats.weeklyTrend.length;
  return <div className="workspace-stats-scroll"><div className="workspace-stats">
    <div className="workspace-stats-grid">{values.map(([value, label]) => <div className="workspace-stat" key={label}><StatValue value={value} /><span>{text(label)}</span></div>)}</div>
    <div className="workspace-rule" />
    <div className="workspace-stat-row"><span>{text('Avg speakers')}</span><b>{state.averageSpeakersLabel}{language === 'ko' ? '명' : ''}</b></div>
    <div className="workspace-rule" />
    <div className="workspace-trend"><div className="workspace-stat-row"><span>{language === 'ko' ? `최근 ${weeks}주` : language === 'ja' ? `直近 ${weeks}週` : `Last ${weeks} wks`}</span><b>{language === 'ko' ? `이번주 ${stats.thisWeekCount}` : language === 'ja' ? `今週 ${stats.thisWeekCount}` : `This week ${stats.thisWeekCount}`}</b></div>
      <div className="workspace-bars" aria-label={stats.weeklyTrend.join(', ')}>{stats.weeklyTrend.map((value, index) => <span key={index} style={{ height: Math.max(15, value / max * 42) }} />)}</div>
    </div>
  </div></div>;
}
const formats: Array<[ExportFormat, string]> = [['md', 'Markdown (.md)'], ['srt', 'Subtitles (.srt)'], ['vtt', 'Subtitles (.vtt)'], ['txt', 'Plain text (.txt)'], ['json', 'JSON (.json)']];
// WorkspaceExplorer's fixed flat panel. Native visual/interaction comparison is
// still required, including the SwiftUI confirmation-dialog presentation.
export function WorkspacePanel({ state, artwork, language, text, hasLines, open, setAutoSave, chooseFolder, showStats, exportFile }: Props) {
  const [mode, setMode] = useState<'files' | 'stats'>('files');
  const [exportMenu, setExportMenu] = useState(false);
  const exportRoot = useRef<HTMLDivElement>(null);
  const exportButton = useRef<HTMLButtonElement>(null);
  const showStatsRef = useRef(showStats); showStatsRef.current = showStats;
  useEffect(() => {
    showStatsRef.current(mode === 'stats');
    return () => showStatsRef.current(false);
  }, [mode]);
  useEffect(() => { if (!hasLines) setExportMenu(false); }, [hasLines]);
  useEffect(() => {
    if (!exportMenu) return;
    const click = (event: PointerEvent) => { if (!exportRoot.current?.contains(event.target as Node)) setExportMenu(false); };
    const escape = (event: KeyboardEvent) => { if (event.key === 'Escape') { event.preventDefault(); setExportMenu(false); exportButton.current?.focus(); } };
    document.addEventListener('pointerdown', click); document.addEventListener('keydown', escape);
    exportRoot.current?.querySelector<HTMLButtonElement>('[role="dialog"] button')?.focus();
    return () => { document.removeEventListener('pointerdown', click); document.removeEventListener('keydown', escape); };
  }, [exportMenu]);
  return <aside className="workspace-panel">
    <div className="workspace-modes" role="group" aria-label={`${text('Files')} / ${text('Stats')}`}><i aria-hidden style={{ transform: mode === 'stats' ? 'translateX(calc(100% + 1px))' : undefined }} />
      {(['files', 'stats'] as const).map(value => <button key={value} aria-pressed={mode === value} onClick={() => setMode(value)}>{text(value === 'files' ? 'Files' : 'Stats')}</button>)}
    </div>
    {mode === 'stats' ? <Stats state={state} language={language} text={text} /> : state.loading ? <div className="workspace-empty"><span className="workspace-spinner" aria-hidden /><span>{text('Reading folder…')}</span></div>
      : state.entries.length ? <div className="workspace-files-scroll"><div className="workspace-files">{state.entries.map(entry => <button key={`${state.generation}:${entry.id}`} onClick={() => open(entry.id)} title={entry.path}>
        <span aria-hidden className="asset-icon" style={{ width: 16, height: 16, maskImage: 'url(/assets/content.svg)' }} /><MiddleText>{entry.name}</MiddleText>
      </button>)}</div></div> : <div className="workspace-empty"><Symbol artwork={artwork} name="folder" /><span>{text('No meetings saved in this folder')}</span></div>}
    <div className="workspace-bottom">
      <div className="workspace-rule" />
      <div className="workspace-auto-save"><span>{text('Auto-save')}</span><button className={`toggle ${state.autoSave ? 'on' : ''}`} role="switch" aria-checked={state.autoSave} aria-label={text('Auto-save')} onClick={() => setAutoSave(!state.autoSave)}><span /></button></div>
      <div className="workspace-folder"><span>{text('Folder')}</span><button title={state.folder} onClick={chooseFolder}><MiddleText>{state.folderName}</MiddleText></button></div>
      <div className="workspace-export" ref={exportRoot}>
        <button ref={exportButton} className="workspace-export-button" disabled={!hasLines} aria-haspopup="dialog" aria-expanded={exportMenu} onClick={() => setExportMenu(value => !value)}><Symbol artwork={artwork} name="export" />{text('Export')}</button>
        {exportMenu && <div className="workspace-export-menu" role="dialog" aria-label={text('Export format')}><span>{text('Export format')}</span>{formats.map(([format, label]) => <button key={format} onClick={() => { setExportMenu(false); exportFile(format); }}>{label}</button>)}<button className="workspace-export-cancel" onClick={() => { setExportMenu(false); exportButton.current?.focus(); }}>{text('Cancel')}</button></div>}
      </div>
    </div>
  </aside>;
}
