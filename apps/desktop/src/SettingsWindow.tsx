import { cloneElement, isValidElement, useEffect, useRef, useState, type CSSProperties, type ReactElement, type ReactNode } from 'react';
import { getCurrentWebviewWindow } from '@tauri-apps/api/webviewWindow';
import { audioInputs, type AudioSource, type InputDevices, type Language } from './bridge';
import { modelSnapshot, type ModelDownload } from './models';
import { workspaceSnapshot, workspaceCommand, chooseWorkspaceFolder } from './workspace';
import { usePreferences, type UILanguage } from './preferences';
import { MiddleText } from './MiddleText';
import { glossarySnapshot, glossaryCommand, manageModels, modelLocations, revealSettings, settingsMetadata, type SettingsMetadata, type ModelLocations } from './settings';
import strings from './settings-strings.generated.json';
import './settings.css';
const table = strings as Record<string, Record<UILanguage, string>>;
const tabNames = {recording: 'Recording', save: 'Save', translation: 'Translation', glossary: 'Glossary', model: 'Model'};
type Tab = keyof typeof tabNames;
function useSnapshot<T extends {revision: number}>(event: string, load: () => Promise<T | null>, failed: (reason: unknown) => void) {
  const [value, setValue] = useState<T | null>(null);
  const failure = useRef(failed); failure.current = failed;
  useEffect(() => {
    let active = true; let unlisten: (() => void) | undefined;
    const receive = (next: T | null) => { if (active) setValue(previous => previous && next && previous.revision > next.revision ? previous : next); };
    void getCurrentWebviewWindow().listen<T>(event, event => receive(event.payload)).then(async cleanup => {
      if (!active) { cleanup(); return; } unlisten = cleanup; receive(await load());
    }).catch(reason => { if (active) failure.current(reason); });
    return () => { active = false; unlisten?.(); };
  }, [event, load]);
  return value;
}
function Section({title, children}: {title?: string; children: ReactNode}) {
  return <section className="settings-section">{title && <h2>{title}</h2>}<div className="settings-card">{children}</div></section>;
}
function Row({label, children, help}: {label: string; children: ReactNode; help?: string}) {
  return <div className="settings-row" title={help}><span>{label}</span>{isValidElement(children) && children.type === 'select'
    ? <span className="settings-popup">{cloneElement(children as ReactElement<{'aria-label'?: string; title?: string}>, {'aria-label':label,title:help})}<i aria-hidden className="settings-popup-indicator"/></span> : children}</div>;
}
function Toggle({label, value, change, disabled, help}: {label: string; value: boolean; change: (value: boolean) => void; disabled?: boolean; help?: string}) {
  return <div className="settings-row" title={help}><span>{label}</span><button className="settings-toggle" role="switch" aria-label={label} aria-checked={value} disabled={disabled} onClick={() => change(!value)}><span /></button></div>;
}
function Range({label, value, min, max, step = .01, change, display, disabled}: {label: string; value: number; min: number; max: number; step?: number; change: (value: number) => void; display: (value: number) => string; disabled?: boolean}) {
  const [draft, setDraft] = useState(value); const dragging = useRef(false);
  useEffect(() => { if (!dragging.current) setDraft(value); }, [value]);
  return <Row label={label}><input type="range" aria-label={label} min={min} max={max} step={step} value={draft} disabled={disabled}
    onPointerDown={() => {dragging.current = true;}} onPointerUp={() => {dragging.current = false;}} onPointerCancel={() => {dragging.current = false;}}
    onChange={event => {const next = Number(event.target.value); setDraft(next); change(next);}} /><output>{display(draft)}</output></Row>;
}
export function SettingsWindow() {
  const {state, settings: change, setupSettings, send, language} = usePreferences();
  const {setup, settings, presentation} = state;
  const [tab, setTab] = useState<Tab>('recording');
  const [error, setError] = useState('');
  const [toolbarListenerReady, setToolbarListenerReady] = useState(false);
  const fail = (reason: unknown) => setError(String(reason));
  const [metadata, setMetadata] = useState<SettingsMetadata | null>(null);
  const [locations, setLocations] = useState<ModelLocations | null>(null);
  const [devices, setDevices] = useState<InputDevices>({supported:false,devices:[],defaultInputId:null});
  const models = useSnapshot('models-changed', modelSnapshot, fail);
  const workspace = useSnapshot('workspace-changed', workspaceSnapshot, fail);
  const glossary = useSnapshot('glossary-changed', glossarySnapshot, fail);
  const queue = useRef(Promise.resolve());
  function act(action: () => Promise<unknown>) {queue.current = queue.current.then(action).then(() => {}, fail);}
  const t = (key: string, values: Record<string,string> = {}) => Object.entries(values).reduce((text,[name,value]) => text.replaceAll(`{${name}}`,value),table[key]?.[language] ?? key);
  useEffect(() => {
    let active = true;
    let unlisten: (() => void) | undefined;
    void getCurrentWebviewWindow().listen<string>('settings-tab-changed', event => {
      if(active && Object.hasOwn(tabNames,event.payload)) setTab(event.payload as Tab);
    }).then(cleanup => {if(!active){cleanup();return;} unlisten=cleanup;setToolbarListenerReady(true);},fail);
    return () => {active=false;unlisten?.();};
  }, []);
  useEffect(() => {
    if(!toolbarListenerReady) return;
    let active = true;
    const refresh = () => {void settingsMetadata().then(value => {if(active)setMetadata(value);}, fail); void audioInputs().then(value => {if(active)setDevices(value);},fail);};
    refresh(); window.addEventListener('focus',refresh);
    return () => {active=false;window.removeEventListener('focus',refresh);};
  }, [language,toolbarListenerReady]);
  useEffect(() => {let active=true; void modelLocations().then(value=>{if(active)setLocations(value);},fail); return()=>{active=false;};},[models?.required.state,models?.translation.state]);
  useEffect(() => {void getCurrentWebviewWindow().setTitle(t(tabNames[tab])).catch(fail);},[tab,language]);
  useEffect(() => {if(tab==='translation') act(()=>manageModels({type:'refreshTranslation'}));},[tab]);
  const tabs = (Object.keys(tabNames) as Tab[]).filter(name=>name!=='translation'||models?.translationEngineAvailable);
  const symbol = (key: string) => {const image=metadata?.artwork?.[key];return image?<i aria-hidden style={{width:image.width,height:image.height,maskImage:`url(${image.dataUrl})`}}/>:null;};
  // AppKit permits a word wrap after path separators without changing the text.
  const note=(key:string,values?:Record<string,string>)=><p className="settings-note">{t(key,values).split(/(?<=\/)/u).map((part,index)=><span key={index}>{part}<wbr/></span>)}</p>;
  const button=(key:string,action:()=>Promise<unknown>,inline=false)=>{const content=<button className="settings-action" onClick={()=>act(action)}>{t(key)}</button>;return inline?content:<div className="settings-button-row">{content}</div>;};
  const toggle=(key:string,value:boolean,change:(value:boolean)=>void,disabled=false,help?:string)=><Toggle label={t(key)} value={value} change={change} disabled={disabled} help={help&&t(help)}/>;
  const translationAvailable=Boolean(models?.translationEngineAvailable&&locations?.translationInstalled);
  const caption=settings.caption;
  const learned=glossary?.displayEntries??[];
  const modelStatus=(value:ModelDownload)=>value.state==='ready'?t('Installed'):value.state==='verifying'?t('Verifying…'):value.state==='downloading'?t('Downloading {percent}%',{percent:String(Math.trunc(value.value*100))}):value.state==='failed'?value.value:t('Not installed');
  return <main className="settings-window" data-native-picker={Boolean(metadata?.artwork?.picker)} style={{'--settings-picker-image':metadata?.artwork?.picker?`url(${metadata.artwork.picker.dataUrl})`:undefined} as CSSProperties}>
    {!metadata?.nativeToolbar && <nav className="settings-tabs" role="tablist" aria-label={language==='ko'?'설정':'Settings'}>
      {tabs.map((name,index)=><button key={name} id={`tab-${name}`} role="tab" tabIndex={tab===name?0:-1} aria-selected={tab===name} aria-controls={`panel-${name}`} onClick={()=>setTab(name)}
        onKeyDown={event=>{const next=event.key==='ArrowRight'?tabs[(index+1)%tabs.length]:event.key==='ArrowLeft'?tabs[(index+tabs.length-1)%tabs.length]:event.key==='Home'?tabs[0]:event.key==='End'?tabs.at(-1):undefined;if(next){event.preventDefault();setTab(next);document.getElementById(`tab-${next}`)?.focus();}}}>
        {symbol(name)}<span>{t(tabNames[name])}</span></button>)}
    </nav>}
    {error&&<p className="settings-error" role="alert">{error}</p>}
    <div key={tab} id={`panel-${tab}`} role="tabpanel" aria-label={t(tabNames[tab])} aria-labelledby={metadata?.nativeToolbar?undefined:`tab-${tab}`} className="settings-form">
      {tab==='recording'&&<>
        <Section title={t('Input')}>
          <Row label={t('Audio source')} help={t('System audio = whatever plays on the Mac (Teams·Slack·Zoom·YouTube …). Mic + system = online meetings (your voice + the other side). First use asks for Screen Recording permission.')}>
            <select value={setup.audioSource} onChange={event=>setupSettings({type:'audioSource',value:event.target.value as AudioSource})}>{(['mic','system','both'] as const).map((value,index)=><option key={value} value={value}>{t(['Microphone','System audio','Mic + system'][index])}</option>)}</select>
          </Row>
          {setup.audioSource!=='system'&&<Row label={t('Microphone')}><select value={setup.inputDeviceId??''} onChange={event=>change({type:'inputDevice',value:event.target.value||null})} onFocus={()=>{void audioInputs().then(setDevices,fail);}}><option value="">{t('System default')}</option>{devices.devices.map(device=><option key={device.id} value={device.id}>{device.name}</option>)}</select></Row>}
          {setup.audioSource!=='mic'&&note('System audio asks for ‘Screen Recording’ permission on first record (audio only; the screen is never saved).')}
          <Row label={t('Language')}><select value={setup.inputLanguage??''} onChange={event=>change({type:'inputLanguage',value:event.target.value as Language||null})}><option value="">{t('Auto-detect')}</option><option value="Korean">{t('Korean')}</option><option value="English">English</option></select></Row>
        </Section>
        <Section title={t('Speakers')}>
          {toggle('Speaker separation',setup.diarize,value=>setupSettings({type:'diarize',value}))}
          {toggle('Overlapping speech detection',setup.osd,value=>change({type:'overlappingSpeech',value}))}
        </Section>
        <Section title={t('Live')}>
          <Row label={t('Response speed')} help={t('Fast = text appears more often; Accurate = more context, better quality.')}><select value={state.effectiveWindowSeconds} onChange={event=>change({type:'liveWindowSeconds',value:Number(event.target.value)})}>{[5,7,10].map((value,index)=><option key={value} value={value}>{t(['Fast (5s)','Normal (7s)','Accurate (10s)'][index])}</option>)}</select></Row>
          {state.multiTranslateForcesAccurate&&note('With 2+ output languages → a floor of ‘Normal (7s)’. ‘Fast (5s)’ becomes 7s automatically, since boundary errors would propagate into every translation.')}
          {toggle('Live preview',settings.livePreviewEnabled,value=>change({type:'livePreview',value}),false,'Shows gray interim text before a window closes (no accuracy cost; shares the resident engine instead of loading a second copy of the model).')}
        </Section>
        <Section title={t('Display')}>
          <Row label="언어 / Language"><div className="settings-segment" role="radiogroup" aria-label="언어 / Language">{(['ko','en','ja'] as const).map((value,index)=><button key={value} role="radio" aria-label={['한국어','English','日本語'][index]} aria-checked={presentation.uiLanguage===value} onClick={()=>send({type:'uiLanguage',value})}>{['한국어','English','日本語'][index]}</button>)}</div></Row>
          <Row label={t('Appearance')}><div className="settings-segment" role="radiogroup" aria-label={t('Appearance')}>{(['system','light','dark'] as const).map((value,index)=><button key={value} role="radio" aria-label={t(['System','Light','Dark'][index])} aria-checked={presentation.appearance===value} onClick={()=>send({type:'appearance',value})}>{t(['System','Light','Dark'][index])}</button>)}</div></Row>
        </Section>
        <Section title={t('Caption overlay (clinic)')}>
          <Range label={t('Staff caption size')} value={caption.staffFontSize} min={14} max={48} step={2} display={value=>`${Math.trunc(value)}pt`} change={value=>change({type:'staffFontSize',value})}/>
          {toggle('Large patient captions (separate display)',caption.patientPanelEnabled,value=>change({type:'patientPanel',value}),false,'Shows a second panel in the patient’s language, at a size readable from across the room.')}
          {caption.patientPanelEnabled&&<>
            <Range label={t('Patient caption size')} value={caption.patientFontSize} min={24} max={96} step={2} display={value=>`${Math.trunc(value)}pt`} change={value=>change({type:'patientFontSize',value})}/>
            {(metadata?.screens.length??0)>1&&<Row label={t('Patient display')}><select value={caption.patientScreenIndex??''} onChange={event=>change({type:'patientScreen',value:event.target.value===''?null:Number(event.target.value)})}><option value="">{t('Main display')}</option>{metadata?.screens.map(screen=><option key={screen.index} value={screen.index}>{t('Display {number}',{number:String(screen.index+1)})} ({screen.width}×{screen.height})</option>)}</select></Row>}
            <Row label={t('Patient language')}><select value={caption.patientLangOverride??''} onChange={event=>change({type:'patientLanguage',value:event.target.value||null})}><option value="">{t('Auto (other party’s)')}</option>{['Japanese','Chinese','English','Korean'].map(value=><option key={value}>{value}</option>)}</select></Row>
          </>}
        </Section>
      </>}
      {tab==='save'&&<>
        <Section title={t('Auto-save')}>
          {workspace&&toggle('Auto-save .md on finish',workspace.autoSave,value=>act(()=>workspaceCommand({type:'autoSave',value})))}
          {workspace?.autoSave&&<div className="settings-row"><span className="secondary">{t('Folder')}</span><MiddleText className="settings-folder">{workspace.folderName}</MiddleText>{button('Change…',chooseWorkspaceFolder,true)}</div>}
        </Section>
        <Section title={t('Diagnostics')}>
          {toggle('Debug capture (session bundle)',settings.debugCapture,value=>change({type:'debugCapture',value}))}
          {note('When on, the next session records engine I/O, audio segments, boundary decisions, translation turns and a memory trace under App Support/Madi/debug/<session>/. Contains session audio and text — keep it local.')}
          {button('Open bundle folder',()=>revealSettings('debug'))}
        </Section>
        <Section title={t('Speech recognition')}>
          <Range label={t('Low-confidence threshold (VAD)')} value={settings.vadConfThreshold} min={.35} max={.9} step={.001} display={value=>value.toFixed(2)} change={value=>change({type:'vadThreshold',value})}/>
          {note('Words below this confidence are flagged ‘needs review’. Default 0.55.')}
        </Section>
      </>}
      {tab==='translation'&&models&&<>
        <Section title={`${t('Translation model')} (${models.translationName} · ~${locations?.translationDiskGb??''} GB)`}>
          <Row label={t('Status')}><span className={models.translation.state==='ready'?'installed':''}>{modelStatus(models.translation)}</span></Row>
          {models.translation.state==='downloading'?<><progress value={models.translation.value} max={1}/>{button('Cancel',()=>manageModels({type:'cancelTranslation'}))}</>:models.translation.state==='ready'?button('Show in Finder',()=>revealSettings('translation')):button('Download translation model',()=>manageModels({type:'download',value:'translation'}))}
          {note('{profile}. Downloaded on demand for local translation (KO·ZH·JA·EN) — measured memory about {ram} GB.',{profile:t(models.variant==='realtime2B'?'Realtime profile for 8 GB Macs':'Quality-default profile'),ram:models.translationRuntimeMemoryGb})}
        </Section>
        <Section title={t('Live translation (multi-target)')}>
          {(['Korean','English','Japanese','Chinese'] as const).map((value,index)=><Toggle key={value} label={['한국어','English','日本語','中文'][index]} value={setup.translateTargets.includes(value)} disabled={!translationAvailable} change={enabled=>change({type:'translationTarget',value:{language:value,enabled}})}/>)}
          {note(translationAvailable?'Each line is translated into every selected language at once, shown under the original (the source language is excluded).':'Download the translation model first.')}
        </Section>
        <Section title={t('Live translation response')}>
          <Range label={t('Wait for last line (s)')} value={settings.translateTailSeconds} min={.5} max={5} display={value=>value.toFixed(1)} change={value=>change({type:'translateTailSeconds',value})}/>
          {note('Waits this long after the last spoken line stops changing before translating it. Shorter shows captions sooner but may translate an unfinished sentence. Committed (next-line-started) lines translate immediately regardless.')}
        </Section>
        <Section title={t('AI correction (after session)')}>
          {toggle('Auto-correct speakers & language',settings.aiReconcileEnabled,value=>change({type:'aiReconcile',value}),!translationAvailable)}
          {note(translationAvailable?'When recording ends, the on-device LLM reads the conversation and conservatively fixes obvious speaker mis-splits and wrong-language lines. Speaker corrections can be undone in one click.':'Requires the translation/summary model ({translation}).',{translation:models.translationName})}
        </Section>
      </>}
      {tab==='glossary'&&glossary&&<>
        <Section title={t('Personal glossary')}>
          {toggle('Auto-apply learned corrections',glossary.glossary.enabled,value=>act(()=>glossaryCommand({type:'enabled',value})))}
          {note('Remembers the fixes you make to frequently-misheard domain terms and names, and auto-corrects similar errors in later meetings. Learning always happens; this switch only controls applying.')}
        </Section>
        <Section title={t('When to apply')}>
          <Range label={t('Minimum hits')} value={glossary.glossary.minHits} min={1} max={5} step={1} disabled={!glossary.glossary.enabled} display={value=>`${value===glossary.glossary.minHits?glossary.minimumHitsLabel:value}×`} change={value=>act(()=>glossaryCommand({type:'minimumHits',value}))}/>
          {note('The same correction must be seen at least this many times before it auto-applies. Higher is more conservative (so one accidental edit won’t overwrite later transcripts).')}
        </Section>
        <Section title={`${t('Learned corrections')} (${glossary.activeCount}/${learned.length})`}>
          {learned.length? <>{learned.map(entry=><div key={entry.wrong} className="settings-row glossary-entry" title={t(entry.active?'Active':'Below the hit threshold — not applied yet')}><del>{entry.wrong}</del>{symbol('arrow')}<strong className={entry.active?'':'inactive'}>{entry.right}</strong><span className={entry.active?'active-hits':'inactive'}>{entry.hitsLabel}×</span><button aria-label={t('Forget this correction')} title={t('Forget this correction')} onClick={()=>act(()=>glossaryCommand({type:'forget',value:entry.wrong}))}>{symbol('trash')}</button></div>)}<div className="settings-button-row"><button className="settings-action destructive" onClick={()=>act(()=>glossaryCommand({type:'clear'}))}>{t('Clear all')}</button></div></>:note('No learned corrections yet. Fix a misrecognized word in a transcript and it accumulates here.')}
        </Section>
      </>}
      {tab==='model'&&<Section>
        <Row label={t('Status')}><span>{t(locations?.transcriptionInstalled?'Installed':'Not installed')}</span></Row>
        <Row label={t('Location')}><MiddleText className="settings-model-path">{locations?.transcription??''}</MiddleText></Row>
        {button('Re-download model',()=>manageModels({type:'download',value:'transcription'}))}
        {button('Show in Finder',()=>revealSettings('transcription'))}
      </Section>}
    </div>
  </main>;
}
