import { StrictMode, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { createRoot } from 'react-dom/client';
import { audioInputs, browserFixture, chooseFile, command, snapshot, watchSetup, type InputDevices, type Language, type MeetingMode, type SetupCommand, type SetupState } from './bridge';
import { MiddleText } from './MiddleText';
import { ModelGate } from './ModelGate';
import { FileTranscript } from './FileTranscript';
import { WorkspacePanel } from './WorkspacePanel';
import { workspaceSnapshot, watchWorkspace, workspaceCommand, chooseWorkspaceFolder, openWorkspaceEntry, exportWorkspace, type WorkspaceSnapshot } from './workspace';
import { copyLine, renameSpeaker, editFile, fileArtwork, fileSnapshot, resetFile, startFile, watchFile, type FileArtwork, type FileEdit, type FileSnapshot } from './files';
import { modelArtwork, modelCommand, modelSnapshot, watchModels, type ModelArtwork, type ModelCommand, type ModelSnapshot } from './models';
import { PreferencesProvider, usePreferences, type UILanguage } from './preferences';
import { SetupIntentQueue } from './SetupIntentQueue';
import './theme.generated.css';
import './styles.css';

const labels: Record<Language, Record<UILanguage, string>> = {
  Korean: { ko: '한국어', en: 'Korean', ja: '韓国語' },
  English: { ko: '영어', en: 'English', ja: 'English' },
  Chinese: { ko: '중국어', en: 'Chinese', ja: 'Chinese' },
  Japanese: { ko: '일본어', en: 'Japanese', ja: 'Japanese' },
};
// Japanese follows the current central table, including English fallbacks.
const inputLanguages: Array<Language | null> = [null, 'Korean', 'English', 'Chinese', 'Japanese'];
const outputLanguages: Language[] = ['Korean', 'English', 'Chinese', 'Japanese'];
const modes: Array<[MeetingMode, string]> = [['general', 'General'], ['oneOnOne', '1:1'], ['standup', 'Standup'], ['interview', 'Interview'], ['lecture', 'Lecture']];

function Icon({ name, size }: { name: string; size: number }) {
  return <span aria-hidden className="asset-icon" style={{ width: size, height: size, maskImage: `url(/assets/${name}.svg)` }} />;
}

function App() {
  const { language: uiLanguage } = usePreferences();
  const [models, setModels] = useState<ModelSnapshot | null | undefined>(undefined);
  const [artwork, setArtwork] = useState<ModelArtwork | null>(null);
  const [error, setError] = useState('');
  const queue = useRef(Promise.resolve());
  useEffect(() => {
    let active = true;
    let unlisten: (() => void) | undefined;
    const receive = (value: ModelSnapshot | null) => {
      if (active) setModels(previous => previous && value && previous.revision > value.revision ? previous : value);
    };
    // Subscribe before reading readiness; a completed download cannot be lost
    // between a snapshot response and installation of the event listener.
    void watchModels(receive).then(async cleanup => {
      if (!active) { cleanup(); return; }
      unlisten = cleanup;
      receive(await modelSnapshot());
    }).catch(reason => { if (active) setError(String(reason)); });
    return () => { active = false; unlisten?.(); };
  }, []);
  const needsGuide = Boolean(models && !models.canEnterApp);
  useEffect(() => {
    if (!needsGuide || artwork) return;
    let active = true;
    void modelArtwork().then(value => {
      if (!value) throw new Error('native model artwork unavailable');
      if (active) setArtwork(value);
    }).catch(reason => { if (active) setError(String(reason)); });
    return () => { active = false; };
  }, [needsGuide, artwork]);
  function send(command: ModelCommand) {
    queue.current = queue.current.then(async () => {
      const value = await modelCommand(command);
      setModels(previous => previous && previous.revision > value.revision ? previous : value);
    }).catch(reason => setError(String(reason)));
  }
  if (error) return <pre role="alert" className="harness-error">{error}</pre>;
  if (models === undefined) return null;
  if (models && !models.canEnterApp) return artwork
    ? <ModelGate snapshot={models} artwork={artwork} language={uiLanguage} send={send} /> : null;
  return <FileSessionScreen />;
}

function FileSessionScreen() {
  const { language: uiLanguage, text } = usePreferences();
  const [state, setState] = useState<FileSnapshot | null>(null);
  const [artwork, setArtwork] = useState<FileArtwork | null>(null);
  const [workspace, setWorkspace] = useState<WorkspaceSnapshot | null>(null);
  const [error, setError] = useState('');
  const queue = useRef(Promise.resolve());
  const workspaceQueue = useRef(Promise.resolve());
  const receive = (value: FileSnapshot) => setState(previous => previous && previous.revision > value.revision ? previous : value);
  useEffect(() => {
    let active = true;
    let unlisten: (() => void) | undefined;
    const changed = (value: FileSnapshot) => { if (active) receive(value); };
    void watchFile(changed).then(async cleanup => {
      if (!active) { cleanup(); return; }
      unlisten = cleanup; changed(await fileSnapshot());
    }).catch(reason => { if (active) setError(String(reason)); });
    return () => { active = false; unlisten?.(); };
  }, []);
  useEffect(() => {
    let active = true;
    let unlisten: (() => void) | undefined;
    const receive = (value: WorkspaceSnapshot | null) => {
      if (active) setWorkspace(previous => previous && value && previous.revision > value.revision ? previous : value);
    };
    void watchWorkspace(receive).then(async cleanup => {
      if (!active) { cleanup(); return; }
      unlisten = cleanup; receive(await workspaceSnapshot());
    }).catch(reason => { if (active) setError(String(reason)); });
    return () => { active = false; unlisten?.(); };
  }, []);
  function changeWorkspace(action: () => Promise<WorkspaceSnapshot>) {
    workspaceQueue.current = workspaceQueue.current.then(async () => {
      const value = await action();
      setWorkspace(previous => previous && previous.revision > value.revision ? previous : value);
    }).catch(reason => setError(String(reason)));
  }
  const hasFile = Boolean(state && state.phase.kind !== 'idle');
  useEffect(() => {
    if (!hasFile || artwork) return;
    let active = true;
    void fileArtwork().then(value => { if (active) setArtwork(value); }).catch(reason => { if (active) setError(String(reason)); });
    return () => { active = false; };
  }, [hasFile, artwork]);
  function perform(action: () => Promise<FileSnapshot>) {
    queue.current = queue.current.then(async () => receive(await action())).catch(reason => setError(String(reason)));
  }
  if (error) return <pre className="harness-error" role="alert">{error}</pre>;
  if (!state) return null;
  if (state.phase.kind === 'idle' && !state.lines.length) return <SetupScreen start={() => perform(startFile)} />;
  return <FileTranscript snapshot={state} artwork={artwork} language={uiLanguage} text={text}
    workspace={workspace && <WorkspacePanel state={workspace} artwork={artwork} language={uiLanguage} text={text} hasLines={state.lines.length > 0}
      open={id => perform(() => openWorkspaceEntry(workspace.generation, id, state.generation))}
      setAutoSave={value => changeWorkspace(() => workspaceCommand({ type: 'autoSave', value }))}
      showStats={value => changeWorkspace(() => workspaceCommand({ type: 'showStats', value }))}
      chooseFolder={() => changeWorkspace(chooseWorkspaceFolder)}
      exportFile={format => { void exportWorkspace(format, state.generation).catch(reason => setError(String(reason))); }} />}
    reset={() => perform(() => resetFile(state.generation))}
    copy={id => { void copyLine(state.generation, id).catch(reason => setError(String(reason))); }}
    rename={speaker => perform(() => renameSpeaker(state.generation, speaker, text))}
    edit={(edit: FileEdit) => perform(() => editFile(state.generation, edit))} />;
}

function SetupScreen({ start }: { start: () => void }) {
  const { language: uiLanguage, text } = usePreferences();
  const languageLabel = (language: string) => labels[language as Language]?.[uiLanguage] ?? language;
  const [state, setState] = useState<SetupState | null>(null);
  const [inputs, setInputs] = useState<InputDevices>({ supported: false, devices: [], defaultInputId: null });
  const [open, setOpen] = useState<string | null>(null);
  const [error, setError] = useState('');
  const [picking, setPicking] = useState(false);
  const [dropTargeted, setDropTargeted] = useState(false);
  const [queue] = useState(() => new SetupIntentQueue(reason => setError(String(reason))));
  const root = useRef<HTMLElement>(null);
  useEffect(() => {
    let active = true;
    let unlisten: (() => void) | undefined;
    const receive = (value: SetupState) => { if (active) setState(previous => previous && previous.revision > value.revision ? previous : value); };
    void watchSetup(receive, value => { if (active) setDropTargeted(value); }).then(async cleanup => {
      if (!active) { cleanup(); return; }
      unlisten = cleanup;
      receive(await snapshot());
    }).catch(value => { if (active) setError(String(value)); });
    audioInputs().then(value => { if (active) setInputs(value); }).catch(value => { if (active) setError(String(value)); });
    return () => { active = false; unlisten?.(); };
  }, []);
  useEffect(() => {
    let active = true;
    const refresh = () => audioInputs().then(value => { if (active) setInputs(value); }).catch(value => { if (active) setError(String(value)); });
    // Refresh at the same visible interaction boundary, and when returning to
    // the app after a device/default-input change in another application.
    if (open === 'mic') void refresh();
    window.addEventListener('focus', refresh);
    return () => { active = false; window.removeEventListener('focus', refresh); };
  }, [open]);
  useLayoutEffect(() => {
    if (!open) return;
    const position = () => {
      const trigger = root.current?.querySelector<HTMLElement>(`[data-trigger="${open}"]`);
      const panel = root.current?.querySelector<HTMLElement>(`#picker-${open}`);
      if (!trigger || !panel) return;
      const frame = trigger.getBoundingClientRect();
      const below = innerHeight - frame.bottom - 16;
      const natural = panel.scrollHeight + 2;
      const flipUp = open === 'mic' && natural > below && frame.top - 8 > natural;
      panel.dataset.direction = flipUp ? 'up' : 'down';
      panel.style.maxHeight = `${flipUp ? frame.top - 16 : Math.max(120, below)}px`;
    };
    position();
    window.addEventListener('resize', position);
    return () => window.removeEventListener('resize', position);
  }, [open, inputs]);
  useEffect(() => {
    const close = (event: PointerEvent) => {
      if (!(event.target instanceof Element) || !event.target.closest('[data-picker]')) setOpen(null);
    };
    const escape = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && open) {
        const trigger = root.current?.querySelector<HTMLButtonElement>(`[data-trigger="${open}"]`);
        setOpen(null); trigger?.focus();
      }
    };
    document.addEventListener('pointerdown', close);
    document.addEventListener('keydown', escape);
    return () => { document.removeEventListener('pointerdown', close); document.removeEventListener('keydown', escape); };
  }, [open]);

  function send(intent: SetupCommand) {
    if (browserFixture) return;
    // Serialize rapid clicks so an older IPC response cannot replace newer UI.
    void queue.enqueue(async () => {
      const next = await command(intent);
      setState(previous => previous && previous.revision > next.revision ? previous : next);
    });
  }

  function pickFile() {
    if (browserFixture || picking) return;
    setOpen(null); setPicking(true);
    void queue.enqueue(async () => {
      const next = await chooseFile();
      setState(previous => previous && previous.revision > next.revision ? previous : next);
    }).finally(() => setPicking(false));
  }

  function picker(id: string, label: string, children: ReactNode, mic = false) {
    return <div className={`picker ${mic ? 'mic-picker' : ''}`} data-picker>
      <button className="pill trigger" data-trigger={id} aria-expanded={open === id} aria-controls={`picker-${id}`}
        onClick={() => setOpen(open === id ? null : id)}>
        <span>{label}</span><span className={`chevron ${open === id ? 'up' : ''}`} aria-hidden />
      </button>
      {open === id && <div id={`picker-${id}`} className="dropdown">{children}</div>}
    </div>;
  }

  if (error) return <pre role="alert" className="harness-error">{error}</pre>;
  if (!state) return null;
  const picked = state.translateTargets.map(languageLabel);
  const outputLabel = picked.length === 0 ? text('No translation') : picked.length === 1 ? picked[0]
    : picked.length === 2 ? picked.join(' · ') : uiLanguage === 'ko' ? `${picked[0]} 외 ${picked.length - 1}`
    : uiLanguage === 'ja' ? `${picked[0]} 他${picked.length - 1}` : `${picked[0]} +${picked.length - 1}`;
  const micDeviceLabel = inputs.devices.find(device => device.id === state.inputDeviceId)?.name
    ?? inputs.devices.find(device => device.id === inputs.defaultInputId)?.name ?? text('System default');
  const micLabel = state.audioSource === 'system' ? text('System audio') : state.audioSource === 'both'
    ? `${micDeviceLabel} + ${uiLanguage === 'ko' ? '시스템' : uiLanguage === 'ja' ? 'システム' : 'system'}` : micDeviceLabel;

  return <main ref={root} className="setup-viewport" data-revision={state.revision}>
    <div className="setup-centering"><div className="setup-content">
      <header>
        <div className="wordmark" role="img" aria-label="Madi" />
        <p className="tagline">{text('Record and your meeting becomes text, translated live — all on this Mac.')}</p>
      </header>
      <div className="setup-columns">
        <section className="meeting-column" aria-labelledby="meeting-heading">
          <h1 id="meeting-heading">{text('Meeting info')}</h1>
          <p className="section-description">{text('Setting up the meeting gives more accurate results.')}</p>
          <div className="meeting-controls">
            <div className="language-row">
              <div><div className="field-title">{text('Input language')}</div>
                {picker('input', state.inputLanguage ? languageLabel(state.inputLanguage) : text('Auto'), inputLanguages.map(language =>
                  <button className="option" key={language ?? 'auto'} onClick={() => { send({ type: 'inputLanguage', value: language }); setOpen(null); }}>
                    {language ? languageLabel(language) : text('Auto')}
                  </button>))}
              </div>
              <div><div className="field-title">{text('Output language')}</div>
                {picker('output', outputLabel, <>
                  <button className="option" onClick={() => send({ type: 'clearTargets' })}>{text('No translation')}<span className={`check ${!picked.length ? 'checked' : ''}`} aria-hidden>{!picked.length ? '✓' : ''}</span></button>
                  {outputLanguages.filter(language => language !== state.inputLanguage).map(language => {
                    const selected = state.translateTargets.includes(language);
                    return <button key={language} className="option" disabled={!selected && picked.length >= 3} aria-pressed={selected}
                      onClick={() => send({ type: 'toggleTarget', value: language })}>
                      {languageLabel(language)}<span className={`check ${selected ? 'checked' : ''}`} aria-hidden>{selected ? '✓' : ''}</span>
                    </button>;
                  })}
                </>)}
              </div>
            </div>
            <div><div className="field-title">{text('Meeting mode')}</div><div className="chips" role="group" aria-label={text('Meeting mode')}>
              {modes.map(([mode, label]) => <button className={`chip ${state.meetingMode === mode ? 'selected' : ''}`} aria-pressed={state.meetingMode === mode} key={mode}
                onClick={() => send({ type: 'meetingMode', value: mode })}>{text(label)}</button>)}
            </div></div>
            <div><div className="field-title speaker-title"><span>{text('Speaker separation')}</span>
              <button className={`toggle ${state.diarize ? 'on' : ''}`} role="switch" aria-checked={state.diarize} aria-label={text('Speaker separation')}
                onClick={() => send({ type: 'diarize', value: !state.diarize })}><span /></button>
            </div><div className={`chips ${state.diarize ? '' : 'inactive'}`} role="group" aria-label={text('Speakers')}>
              {[0, 2, 3, 4, 5].map(count => <button key={count} disabled={!state.diarize} className={`chip ${state.speakerCount === count ? 'selected' : ''}`}
                aria-pressed={state.speakerCount === count} onClick={() => send({ type: 'speakerCount', value: count })}>
                {count === 0 ? text('Auto') : uiLanguage === 'ko' ? `${count}명${count === 5 ? ' 이상' : ''}` : uiLanguage === 'ja' ? `${count}名${count === 5 ? '以上' : ''}` : `${count}${count === 5 ? '+' : ''}`}
              </button>)}
            </div></div>
          </div>
        </section>
        <div className="column-divider" />
        <section className="start-column" aria-labelledby="start-heading">
          <h1 id="start-heading">{text('Get started')}</h1>
          <p className="section-description">{text('Pick an audio or video file, or start recording now.')}</p>
          <div className="start-controls">
            {state.stagedFile ? <div className="staged-file">
              <div className="staged-details"><Icon name="content" size={20} />
                <div className="staged-labels"><MiddleText className="staged-name">{state.stagedFile.name}</MiddleText>
                  <span className="staged-size">{state.stagedFile.sizeLabel}</span></div>
              </div>
              <button className="clear-file" aria-label={text('Close')} onClick={() => send({ type: 'clearStagedFile' })}><Icon name="close" size={13} /></button>
            </div> : <button className={`drop-zone ${dropTargeted ? 'targeted' : ''}`} disabled={picking} onClick={pickFile}>
              <Icon name="folder-plus" size={24} /><span>{text('Choose file or drag & drop')}</span>
            </button>}
            <button className={`cta ${state.stagedFile ? '' : 'unavailable'}`} aria-disabled={!state.stagedFile}
              onClick={() => { if (state.stagedFile) void queue.enqueue(start); }}>{text('Start from file')}</button>
            <div className="or-divider"><span /><span>or</span><span /></div>
            <div className="record-row">
              {picker('mic', micLabel, <>
                {[{ id: null, name: text('System default') }, ...inputs.devices].map(device => {
                  const selected = state.audioSource !== 'system' && state.inputDeviceId === device.id;
                  return <button key={device.id ?? 'default'} className="option" aria-pressed={selected}
                    onClick={() => { send({ type: 'inputDevice', value: device.id }); setOpen(null); }}>
                    <MiddleText className="device-name">{device.name}</MiddleText><span className="menu-check" aria-hidden>{selected ? '✓' : ''}</span>
                  </button>;
                })}
                <hr />
                {(['system', 'both'] as const).map(value => <button key={value} className="option" aria-pressed={state.audioSource === value} onClick={() => { send({ type: 'audioSource', value }); setOpen(null); }}>{text(value === 'system' ? 'System audio' : 'Mic + system')}<span className="menu-check" aria-hidden>{state.audioSource === value ? '✓' : ''}</span></button>)}
              </>, true)}
              <button className={`cta ${state.stagedFile ? 'unavailable' : ''}`} aria-disabled={!!state.stagedFile}
                onClick={() => { if (!state.stagedFile) window.dispatchEvent(new CustomEvent('madi-parity-intent', { detail: 'start-recording' })); }}>{text('Start recording now')}</button>
            </div>
          </div>
        </section>
      </div>
    </div></div>
  </main>;
}

createRoot(document.getElementById('root')!).render(<StrictMode><PreferencesProvider><App /></PreferencesProvider></StrictMode>);
