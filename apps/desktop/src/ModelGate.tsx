import type { ModelArtwork, ModelCommand, ModelDownload, ModelSnapshot } from './models';
import copy from './model-strings.generated.json';
import './model-gate.css';

type Language = 'ko' | 'en' | 'ja';
const strings = copy as Record<string, Record<Language, string>>;

// Layout, labels and conditional actions follow ModelGateView.swift. Native
// snapshots own readiness, download policy, formatting and all file/network I/O.
export function ModelGate({ snapshot: s, artwork, language, send }: {
  snapshot: ModelSnapshot; artwork: ModelArtwork; language: Language; send: (command: ModelCommand) => void;
}) {
  const t = (key: string, values: Record<string, string | number> = {}) => {
    const template = strings[key]?.[language] ?? key;
    return template.replace(/\{(\w+)\}/g, (_, name: string) => String(values[name] ?? `{${name}}`));
  };
  function symbol(name: keyof ModelArtwork) {
    const image = artwork[name];
    return <span aria-hidden className="model-symbol" style={{ width: image.width, height: image.height, maskImage: `url("${image.dataUrl}")` }} />;
  }
  function status(state: ModelDownload, required: boolean) {
    if (!required && !s.translationEngineAvailable) return t('Engine unavailable');
    switch (state.state) {
      case 'ready': return t('Installed');
      case 'checking': return t('Checking');
      case 'downloading': return `${Math.trunc(state.value * 100)}%`;
      case 'verifying': return t('Verifying');
      case 'failed': return t('Failed');
      case 'cancelled': return t('Cancelled');
      case 'idle': return t(required ? 'Not downloaded' : 'Optional');
    }
  }
  function card(required: boolean, title: string, badge: string, subtitle: string, detail: string, state: ModelDownload) {
    const label = status(state, required);
    const progress = state.state === 'downloading' ? state.value : state.state === 'verifying' ? 1 : null;
    const color = label === t('Installed') ? 'installed' : label === t('Failed') ? 'failed' : '';
    return <section className={`model-card ${required ? 'required' : 'optional'}`} aria-label={title}
      style={{ opacity: !required && !s.translationEngineAvailable ? 0.65 : 1 }}>
      <div className="model-card-top">
        <div className="model-card-icon">{symbol(required ? 'required' : 'translation')}</div>
        <div className="model-card-copy">
          <div className="model-card-title"><span>{title}</span><span className="model-badge">{badge}</span></div>
          <p className="model-subtitle">{subtitle}</p><p className="model-detail">{detail}</p>
        </div>
        <span className={`model-status ${color}`}>{label}</span>
      </div>
      {progress !== null && <progress aria-label={title} max={1} value={progress} />}
      {state.state === 'failed' && <p className="model-download-error" role="alert">{symbol('error')}<span>{state.value}</span></p>}
    </section>;
  }
  const profile = t(s.variant === 'realtime2B' ? 'Realtime-first for 8 GB Macs' : 'Quality-first');
  return <main className="model-viewport" data-model-revision={s.revision}>
    <div className="model-content">
      <header className="model-header">
        <div className="model-header-icon">{symbol('header')}</div>
        <h1>{t('Set up Madi for this Mac')}</h1>
        <p>{t('Choose the required transcription model and the optional AI model. This is a one-time download.')}</p>
        <span className="model-memory">{t('This Mac: {memory} GB memory · {translation} recommended', { memory: s.memoryGb, translation: s.translationName })}</span>
      </header>
      <div className="model-cards">
        {card(true, 'Whisper large-v3 Turbo Q8', t('Required'),
          t('Transcription · speaker separation · live preview'),
          t("Madi's native Zig/Metal engine · {requiredSize} download", { requiredSize: s.requiredSize }), s.required)}
        {card(false, s.translationName, t('Optional · Recommended'),
          t('Translation · AI correction · summary · Q&A'),
          t('{profile} · {translationSize} download · measured runtime memory ~{ram} GB', {
            profile, translationSize: s.translationSize, ram: s.translationRuntimeMemoryGb,
          }), s.translation)}
      </div>
      <div className={`model-actions ${s.choice === null ? 'unselected' : 'selected'}`}>
        {s.choice === null ? <>
          {s.translationEngineAvailable && <button className="model-button prominent" onClick={() => send({ type: 'start', value: 'recommended' })}>
            {t('Download recommended setup · {size}', { size: s.recommendedDownloadSize })}</button>}
          <button className="model-button" onClick={() => send({ type: 'start', value: 'transcriptionOnly' })}>
            {t('Set up transcription only · {size}', { size: s.transcriptionDownloadSize })}</button>
          <p className="model-hint">{t('You can download DNA later in Settings (⌘,) → Translation.')}</p>
        </> : <>
          {s.hasRetryableDownload && <button className="model-button prominent" onClick={() => send({ type: 'retry' })}>{t('Retry failed downloads')}</button>}
          {s.canContinueTranscription && <button className="model-button prominent" onClick={() => send({ type: 'continueTranscription' })}>{t('Start transcribing while DNA continues')}</button>}
          {s.isDownloading && <button className="model-cancel" onClick={() => send({ type: 'cancel' })}>{t('Cancel downloads')}</button>}
        </>}
      </div>
      <p className="model-privacy">{symbol('privacy')}<span>{t('Only the models are downloaded. Meeting audio and transcripts never leave this Mac.')}</span></p>
    </div>
  </main>;
}
