import { invoke, isTauri } from '@tauri-apps/api/core';

export type Language = 'Chinese' | 'English' | 'Japanese' | 'Korean';
export type MeetingMode = 'general' | 'oneOnOne' | 'standup' | 'interview' | 'lecture';
export type AudioSource = 'mic' | 'system' | 'both';
export interface SetupState {
  revision: number;
  inputLanguage: Language | null;
  translateTargets: Language[];
  meetingMode: MeetingMode;
  diarize: boolean;
  speakerCount: number;
  audioSource: AudioSource;
}
export type SetupCommand =
  | { type: 'inputLanguage'; value: Language | null }
  | { type: 'toggleTarget'; value: Language }
  | { type: 'clearTargets' }
  | { type: 'meetingMode'; value: MeetingMode }
  | { type: 'diarize'; value: boolean }
  | { type: 'speakerCount'; value: number }
  | { type: 'audioSource'; value: AudioSource };

// A browser reference is explicitly opt-in, read-only, and has no mock command
// implementation. Interactive parity must exercise the actual Rust host.
export const browserFixture = !isTauri() && import.meta.env.DEV
  && new URLSearchParams(location.search).get('fixture') === 'setup';

export async function snapshot(): Promise<SetupState> {
  if (browserFixture) {
    return {
      revision: 0, inputLanguage: null, translateTargets: [], meetingMode: 'general',
      diarize: true, speakerCount: 0, audioSource: 'mic',
    };
  }
  return invoke<SetupState>('setup_snapshot');
}

export function command(command: SetupCommand): Promise<SetupState> {
  return invoke<SetupState>('setup_command', { command });
}
