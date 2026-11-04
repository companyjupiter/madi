import { invoke, isTauri } from '@tauri-apps/api/core';
import { getCurrentWebviewWindow } from '@tauri-apps/api/webviewWindow';

export type Language = 'Chinese' | 'English' | 'Japanese' | 'Korean';
export type MeetingMode = 'general' | 'oneOnOne' | 'standup' | 'interview' | 'lecture';
export type AudioSource = 'mic' | 'system' | 'both';
export interface InputDevices {
  supported: boolean;
  devices: Array<{ id: string; name: string }>;
  defaultInputId: string | null;
}
export interface SetupState {
  revision: number;
  inputLanguage: Language | null;
  translateTargets: string[];
  meetingMode: MeetingMode;
  diarize: boolean;
  osd: boolean;
  speakerCount: number;
  audioSource: AudioSource;
  inputDeviceId: string | null;
  stagedFile: { name: string; sizeLabel: string } | null;
}
export type SetupCommand =
  | { type: 'inputLanguage'; value: Language | null }
  | { type: 'toggleTarget'; value: Language }
  | { type: 'clearTargets' }
  | { type: 'clearStagedFile' }
  | { type: 'meetingMode'; value: MeetingMode }
  | { type: 'diarize'; value: boolean }
  | { type: 'speakerCount'; value: number }
  | { type: 'audioSource'; value: AudioSource }
  | { type: 'inputDevice'; value: string | null };

// A browser reference is explicitly opt-in, read-only, and has no mock command
// implementation. Interactive parity must exercise the actual Rust host.
export const browserFixture = !isTauri() && import.meta.env.DEV
  && new URLSearchParams(location.search).get('fixture') === 'setup';

export async function snapshot(): Promise<SetupState> {
  if (browserFixture) {
    return {
      revision: 0, inputLanguage: null, translateTargets: [], meetingMode: 'general',
      diarize: true, osd: true, speakerCount: 0, audioSource: 'mic', inputDeviceId: null, stagedFile: null,
    };
  }
  return invoke<SetupState>('setup_snapshot');
}

export async function audioInputs(): Promise<InputDevices> {
  if (browserFixture) return { supported: false, devices: [], defaultInputId: null };
  return invoke<InputDevices>('audio_inputs');
}

export function command(command: SetupCommand): Promise<SetupState> {
  return invoke<SetupState>('setup_command', { command });
}

export function chooseFile(): Promise<SetupState> {
  return invoke<SetupState>('choose_file');
}

export async function watchSetup(changed: (state: SetupState) => void, dragged: (targeted: boolean) => void) {
  if (browserFixture) return () => {};
  const window = getCurrentWebviewWindow();
  const unlistenState = await window.listen<SetupState>('setup-changed', event => changed(event.payload));
  try {
    const unlistenDrag = await window.listen<boolean>('media-drag-target', event => dragged(event.payload));
    return () => { unlistenState(); unlistenDrag(); };
  } catch (error) { unlistenState(); throw error; }
}
