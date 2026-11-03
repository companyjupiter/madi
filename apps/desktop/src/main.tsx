import { StrictMode, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { createRoot } from 'react-dom/client';
import { audioInputs, browserFixture, command, snapshot, type InputDevices, type Language, type MeetingMode, type SetupCommand, type SetupState } from './bridge';
import strings from './strings.generated.json';
import './theme.generated.css';
import './styles.css';

type UILanguage = 'ko' | 'en' | 'ja';
const parameters = new URLSearchParams(location.search);
const uiLanguage: UILanguage = parameters.get('lang') === 'en' ? 'en' : parameters.get('lang') === 'ja' ? 'ja' : 'ko';
const table = strings as Record<string, Record<UILanguage, string>>;
const text = (english: string) => table[english]?.[uiLanguage] ?? english;
const labels: Record<Language, Record<UILanguage, string>> = {
  Korean: { ko: '한국어', en: 'Korean', ja: '韓国語' },
  English: { ko: '영어', en: 'English', ja: 'English' },
  Chinese: { ko: '중국어', en: 'Chinese', ja: 'Chinese' },
  Japanese: { ko: '일본어', en: 'Japanese', ja: 'Japanese' },
};
// Japanese follows the current central table, including English fallbacks.
const languageLabel = (language: Language) => labels[language][uiLanguage];
const inputLanguages: Array<Language | null> = [null, 'Korean', 'English', 'Chinese', 'Japanese'];
const outputLanguages: Language[] = ['Korean', 'English', 'Chinese', 'Japanese'];
const modes: Array<[MeetingMode, string]> = [['general', 'General'], ['oneOnOne', '1:1'], ['standup', 'Standup'], ['interview', 'Interview'], ['lecture', 'Lecture']];

function Icon({ name, size }: { name: string; size: number }) {
  return <span aria-hidden className="asset-icon" style={{ width: size, height: size, maskImage: `url(/assets/${name}.svg)` }} />;
}

function App() {
  const [state, setState] = useState<SetupState | null>(null);
  const [inputs, setInputs] = useState<InputDevices>({ supported: false, devices: [], defaultInputId: null });
  const [open, setOpen] = useState<string | null>(null);
  const [error, setError] = useState('');
  const queue = useRef(Promise.resolve());
  const root = useRef<HTMLElement>(null);
  useEffect(() => {
    let active = true;
    snapshot().then(value => { if (active) setState(value); }).catch(value => { if (active) setError(String(value)); });
    audioInputs().then(value => { if (active) setInputs(value); }).catch(value => { if (active) setError(String(value)); });
    return () => { active = false; };
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
    queue.current = queue.current.then(async () => {
      const next = await command(intent);
      setState(previous => previous && previous.revision > next.revision ? previous : next);
    }).catch(reason => setError(String(reason)));
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
            <button className="drop-zone" onClick={() => window.dispatchEvent(new CustomEvent('madi-parity-intent', { detail: 'choose-file' }))}>
              <Icon name="folder-plus" size={24} /><span>{text('Choose file or drag & drop')}</span>
            </button>
            <button className="cta unavailable" aria-disabled="true">{text('Start from file')}</button>
            <div className="or-divider"><span /><span>or</span><span /></div>
            <div className="record-row">
              {picker('mic', micLabel, <>
                {[{ id: null, name: text('System default') }, ...inputs.devices].map(device => {
                  const selected = state.audioSource !== 'system' && state.inputDeviceId === device.id;
                  return <button key={device.id ?? 'default'} className="option" aria-pressed={selected}
                    onClick={() => { send({ type: 'inputDevice', value: device.id }); setOpen(null); }}>
                    <span className="device-name">{device.name}</span><span className="menu-check" aria-hidden>{selected ? '✓' : ''}</span>
                  </button>;
                })}
                <hr />
                {(['system', 'both'] as const).map(value => <button key={value} className="option" aria-pressed={state.audioSource === value} onClick={() => { send({ type: 'audioSource', value }); setOpen(null); }}>{text(value === 'system' ? 'System audio' : 'Mic + system')}<span className="menu-check" aria-hidden>{state.audioSource === value ? '✓' : ''}</span></button>)}
              </>, true)}
              <button className="cta" onClick={() => window.dispatchEvent(new CustomEvent('madi-parity-intent', { detail: 'start-recording' }))}>{text('Start recording now')}</button>
            </div>
          </div>
        </section>
      </div>
    </div></div>
  </main>;
}

document.documentElement.lang = uiLanguage;
const appearance = parameters.get('theme');
const media = matchMedia('(prefers-color-scheme: dark)');
const applyAppearance = () => { document.documentElement.dataset.theme = appearance === 'light' || appearance === 'dark' ? appearance : media.matches ? 'dark' : 'light'; };
applyAppearance();
media.addEventListener('change', applyAppearance);
createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>);
