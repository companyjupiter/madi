import { createContext, useContext, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { getCurrentWebviewWindow } from '@tauri-apps/api/webviewWindow';
import { browserFixture, type SetupState } from './bridge';
import strings from './strings.generated.json';

export type UILanguage = 'ko' | 'en' | 'ja';
export interface Presentation { uiLanguage: UILanguage; appearance: 'system' | 'light' | 'dark'; contentMode: boolean; fontSize: number }
interface Preferences { revision: number; setup: SetupState; presentation: Presentation }
export type PresentationCommand = { type: 'uiLanguage'; value: UILanguage } | { type: 'appearance'; value: Presentation['appearance'] } | { type: 'contentMode'; value: boolean } | { type: 'smallerText' | 'largerText' };
interface Context { presentation: Presentation; language: UILanguage; text: (key: string) => string; send: (command: PresentationCommand) => void }
const context = createContext<Context | null>(null);
export function usePreferences() { const value = useContext(context); if (!value) throw new Error('preferences not ready'); return value; }
const parameters = new URLSearchParams(location.search);
const table = strings as Record<string, Record<UILanguage, string>>;
export function PreferencesProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<Preferences | null>(null);
  const [error, setError] = useState('');
  const queue = useRef(Promise.resolve());
  const receive = (value: Preferences) => setState(previous => previous && previous.revision > value.revision ? previous : value);
  useEffect(() => {
    let active = true;
    let unlisten: (() => void) | undefined;
    if (browserFixture) {
      setState({ revision: 0, setup: {} as SetupState, presentation: { uiLanguage: 'ko', appearance: 'system', contentMode: true, fontSize: 16 } });
      return;
    }
    void getCurrentWebviewWindow().listen<Preferences>('preferences-changed', event => { if (active) receive(event.payload); }).then(async cleanup => {
      if (!active) { cleanup(); return; }
      unlisten = cleanup;
      const value = await invoke<Preferences>('preferences_snapshot');
      if (active) receive(value);
    }).catch(reason => { if (active) setError(String(reason)); });
    return () => { active = false; unlisten?.(); };
  }, []);
  // URL overrides remain transient tools for capture parity, never stored.
  const lang = parameters.get('lang');
  const language = lang === 'ko' || lang === 'en' || lang === 'ja' ? lang : state?.presentation.uiLanguage ?? 'ko';
  const theme = parameters.get('theme');
  const appearance = theme === 'system' || theme === 'light' || theme === 'dark' ? theme : state?.presentation.appearance ?? 'system';
  useLayoutEffect(() => {
    document.documentElement.lang = language;
    const media = matchMedia('(prefers-color-scheme: dark)');
    const apply = () => { document.documentElement.dataset.theme = appearance === 'system' ? media.matches ? 'dark' : 'light' : appearance; };
    apply(); media.addEventListener('change', apply);
    return () => media.removeEventListener('change', apply);
  }, [language, appearance]);
  function send(command: PresentationCommand) {
    if (browserFixture) return;
    queue.current = queue.current.then(async () => receive(await invoke<Preferences>('preferences_command', { command }))).catch(reason => setError(String(reason)));
  }
  if (error) return <pre className="harness-error" role="alert">{error}</pre>;
  if (!state) return null;
  return <context.Provider value={{ presentation: state.presentation, language, text: key => table[key]?.[language] ?? key, send }}>{children}</context.Provider>;
}
