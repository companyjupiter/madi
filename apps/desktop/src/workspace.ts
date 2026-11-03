import { invoke } from '@tauri-apps/api/core';
import { getCurrentWebviewWindow } from '@tauri-apps/api/webviewWindow';
import { browserFixture } from './bridge';
import type { FileSnapshot } from './files';
export interface WorkspaceSnapshot {
  revision: number; generation: number; rootRevision: number; loading: boolean;
  autoSave: boolean; folder: string; folderName: string;
  entries: Array<{ id: string; name: string; path: string }>;
  stats: { meetingCount: number; totalSeconds: number; totalWords: number; speakerSum: number; thisWeekCount: number; weeklyTrend: number[]; avgSeconds: number; avgSpeakers: number };
  totalWordsLabel: string; averageSpeakersLabel: string; statsLoading: boolean; error: string | null;
}
export type WorkspaceCommand = { type: 'autoSave' | 'showStats'; value: boolean };
export type ExportFormat = 'md' | 'srt' | 'vtt' | 'txt' | 'json';
export const workspaceSnapshot = () => browserFixture ? Promise.resolve(null) : invoke<WorkspaceSnapshot | null>('workspace_snapshot');
export const workspaceCommand = (command: WorkspaceCommand) => invoke<WorkspaceSnapshot>('workspace_command', { command });
export const chooseWorkspaceFolder = () => invoke<WorkspaceSnapshot>('workspace_choose_folder');
export const openWorkspaceEntry = (generation: number, id: string, fileGeneration: number) => invoke<FileSnapshot>('workspace_open', { generation, id, fileGeneration });
export const exportWorkspace = (format: ExportFormat, fileGeneration: number) => invoke<void>('workspace_export', { format, fileGeneration });
export async function watchWorkspace(changed: (snapshot: WorkspaceSnapshot) => void) {
  if (browserFixture) return () => {};
  return getCurrentWebviewWindow().listen<WorkspaceSnapshot>('workspace-changed', event => changed(event.payload));
}
