import { invoke } from '@tauri-apps/api/core';
import { getCurrentWebviewWindow } from '@tauri-apps/api/webviewWindow';
import { browserFixture } from './bridge';

export type ModelChoice = 'transcriptionOnly' | 'recommended';
export type ModelDownload =
  | { state: 'idle' | 'checking' | 'verifying' | 'ready' | 'cancelled' }
  | { state: 'downloading'; value: number }
  | { state: 'failed'; value: string };
export interface ModelSnapshot {
  revision: number;
  required: ModelDownload;
  translation: ModelDownload;
  choice: ModelChoice | null;
  variant: 'quality4B' | 'realtime2B';
  physicalMemory: number;
  translationEngineAvailable: boolean;
  canEnterApp: boolean;
  canContinueTranscription: boolean;
  hasRetryableDownload: boolean;
  isDownloading: boolean;
  memoryGb: number;
  translationName: string;
  translationRuntimeMemoryGb: string;
  requiredSize: string;
  translationSize: string;
  transcriptionDownloadSize: string;
  recommendedDownloadSize: string;
}
export type ModelCommand = { type: 'start'; value: ModelChoice }
  | { type: 'retry' | 'cancel' | 'continueTranscription' };
export type ModelArtwork = Record<'header' | 'required' | 'translation' | 'privacy' | 'error',
  { dataUrl: string; width: number; height: number }>;

export async function modelSnapshot(): Promise<ModelSnapshot | null> {
  if (browserFixture) return null;
  return invoke<ModelSnapshot | null>('models_snapshot');
}
export function modelArtwork(): Promise<ModelArtwork | null> {
  return invoke<ModelArtwork | null>('models_artwork');
}
export function modelCommand(command: ModelCommand): Promise<ModelSnapshot> {
  return invoke<ModelSnapshot>('models_command', { command });
}
export async function watchModels(changed: (snapshot: ModelSnapshot) => void) {
  if (browserFixture) return () => {};
  return getCurrentWebviewWindow().listen<ModelSnapshot>('models-changed', event => changed(event.payload));
}
