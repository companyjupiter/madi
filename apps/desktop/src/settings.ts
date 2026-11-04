import { invoke } from '@tauri-apps/api/core';
import type { AudioSource, Language } from './bridge';
import type { ModelSnapshot } from './models';
export interface SessionSettings {
  liveWindowSeconds: number; translateTailSeconds: number; livePreviewEnabled: boolean;
  aiReconcileEnabled: boolean; debugCapture: boolean; vadConfThreshold: number;
  caption: {staffFontSize: number; patientFontSize: number; panelWidth: number; minScaleFactor: number; patientPanelEnabled: boolean; patientScreenIndex: number | null; patientLangOverride: string | null};
}
export type SettingsCommand = {type: 'inputLanguage'; value: Language | null}
  | {type: 'inputDevice'; value: string | null}
  | {type: 'translationTarget'; value: {language: Language; enabled: boolean}}
  | {type: 'overlappingSpeech' | 'livePreview' | 'aiReconcile' | 'debugCapture' | 'patientPanel'; value: boolean}
  | {type: 'liveWindowSeconds' | 'translateTailSeconds' | 'vadThreshold' | 'staffFontSize' | 'patientFontSize'; value: number}
  | {type: 'patientScreen'; value: number | null} | {type: 'patientLanguage'; value: string | null};
export type SettingsSetupCommand = {type: 'audioSource'; value: AudioSource} | {type: 'diarize'; value: boolean};
export interface GlossarySnapshot { revision: number; displayEntries: Array<{wrong: string; right: string; hitsLabel: string; active: boolean}>; minimumHitsLabel: string; activeCount: number; glossary: {enabled: boolean; minHits: number; entries: Record<string,{wrong: string; right: string; hits: number}>} }
export type GlossaryCommand = {type: 'enabled'; value: boolean} | {type: 'minimumHits'; value: number} | {type: 'forget'; value: string} | {type: 'clear'};
export interface SettingsMetadata { nativeToolbar?: boolean; artwork: Record<string,{dataUrl: string; width: number; height: number}> | null; screens: Array<{index: number; width: number; height: number}> }
export interface ModelLocations { transcription: string; translation: string; transcriptionInstalled: boolean; translationInstalled: boolean; translationDiskGb: string }
export type ManagementCommand = {type: 'download'; value: 'transcription' | 'translation'} | {type: 'refreshTranslation' | 'cancelTranslation'};
export const openSettings = () => invoke<void>('settings_open');
export const settingsMetadata = () => invoke<SettingsMetadata>('settings_metadata');
export const glossarySnapshot = () => invoke<GlossarySnapshot>('glossary_snapshot');
export const glossaryCommand = (command: GlossaryCommand) => invoke<GlossarySnapshot>('glossary_command', {command});
export const modelLocations = () => invoke<ModelLocations | null>('settings_model_locations');
export const manageModels = (command: ManagementCommand) => invoke<ModelSnapshot>('settings_models_command', {command});
export const revealSettings = (destination: 'transcription' | 'translation' | 'debug') => invoke<void>('settings_reveal', {destination});
