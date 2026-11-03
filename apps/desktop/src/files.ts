import { invoke } from '@tauri-apps/api/core';
import { getCurrentWebviewWindow } from '@tauri-apps/api/webviewWindow';
import { browserFixture } from './bridge';

export interface TranscriptLine {
  id: string; speaker: number; start: number; end: number; text: string; sourceRevision: string;
  words: Array<{ id: string; t0: number; t1: number; text: string; conf: number }>;
  speakerMargin: number; overlapSpeakers: number[]; editedText: string | null;
  translations: Record<string, string>; staleTranslations: Record<string, string>;
  editedTranslations: string[]; suppressedTranslations: string[];
}
export interface FileSnapshot {
  revision: number; generation: number;
  phase: { kind: 'idle' | 'processing' | 'done' } | { kind: 'error'; message: string };
  fileName: string; sizeLabel: string; chunksDone: number; chunksTotal: number;
  lines: TranscriptLine[]; speakerNumbers: { numbers: Record<string, number> };
  speakerNames: Record<string, string>; partial: string; speakerIslandAbsorption: boolean;
  archive: { enabled: boolean; folder: string | null; transcript: string | null; error: string | null };
}
export type FileArtwork = Record<'follow', { dataUrl: string; width: number; height: number }>;
export const fileArtwork = () => invoke<FileArtwork | null>('file_artwork');
export type FileEdit =
  | { type: 'line'; id: string; text: string }
  | { type: 'word'; id: string; index: number; text: string }
  | { type: 'translation'; id: string; language: string; text: string }
  | { type: 'speakerName'; speaker: number; name: string };
export const emptyFile: FileSnapshot = { revision: 0, generation: 0, phase: { kind: 'idle' }, fileName: '', sizeLabel: '', chunksDone: 0, chunksTotal: 0, lines: [], speakerNumbers: { numbers: {} }, speakerNames: {}, partial: '', speakerIslandAbsorption: false, archive: { enabled: false, folder: null, transcript: null, error: null } };
export const fileSnapshot = () => browserFixture ? Promise.resolve(emptyFile) : invoke<FileSnapshot>('file_snapshot');
export const startFile = () => invoke<FileSnapshot>('file_start');
export const resetFile = (generation: number) => invoke<FileSnapshot>('file_reset', { generation });
export const editFile = (generation: number, edit: FileEdit) => invoke<FileSnapshot>('file_edit', { generation, edit });
export const copyLine = (generation: number, id: string) => invoke<void>('file_copy_line', { generation, id });
export const renameSpeaker = (generation: number, speaker: number, text: (key: string) => string) => invoke<FileSnapshot>('file_rename_speaker', { generation, speaker, labels: {
  title: text('Speaker name'), message: text('Applies to all of this speaker’s lines and exports.'), placeholder: text('Name (e.g. Alex)'), save: text('Save'), cancel: text('Cancel'),
} });
export async function watchFile(changed: (snapshot: FileSnapshot) => void) {
  if (browserFixture) return () => {};
  return getCurrentWebviewWindow().listen<FileSnapshot>('file-session-changed', event => changed(event.payload));
}
