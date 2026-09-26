export type RuleMode = 'observe' | 'overlay' | 'replace';
export type ReplaceStrategy = 'skip_original' | 'stop_playing_id';

export interface AudioCandidate {
  file: string;
  action?: AudioAction;
  weight?: number;
  volume?: number;
  speed?: number;
  maxDurationMs?: number;
}

export interface AudioAction {
  controllerIndex: number;
  category: number;
  index: number;
  typeName?: string;
}

export interface VoiceRule {
  id: string;
  enabled?: boolean;
  eventId: string;
  triggerId: string;
  action?: AudioAction;
  mode?: RuleMode;
  replaceStrategy?: ReplaceStrategy;
  cooldownMs?: number;
  maxConcurrent?: number;
  candidates: AudioCandidate[];
}

// 来自 Groups 文件夹的分组带 source（folder 就是分组 id）；分组文件夹本身就是分发单元。
export interface GroupSource {
  folder: string;
  version?: string | null;
  author?: string | null;
  hasManifest?: boolean;
}

export interface RuleGroup {
  id: string;
  name?: string;
  audioDirectory?: string;
  enabled?: boolean;
  source?: GroupSource;
  rules: VoiceRule[];
}

export interface ReplacementConfig {
  schemaVersion: number;
  enabled: boolean;
  mode: RuleMode;
  replaceStrategy?: ReplaceStrategy;
  groups: RuleGroup[];
  blockedSourcePrefixes?: string[];
}

export type PlaybackStatus = 'trying' | 'success' | 'failed';

export interface AudioEvent {
  sequence: number;
  capturedAt?: string;
  category?: string;
  stableKey: string;
  eventId: string;
  triggerId: string;
  origin?: string;
  sourcePath?: string;
  sourceObject?: string;
  triggerCount?: number;
  firstCapturedAt?: string;
  lastCapturedAt?: string;
  replayable?: boolean;
  playbackStatus?: PlaybackStatus;
  playbackError?: string;
  durationMs?: number;
  note?: string;
  savedAt?: string;
  observedActions?: AudioAction[];
}

export interface CatalogEntry {
  file: string;
  durationMs?: number;
  name?: string;
  extension?: string;
  groupDirectory?: string;
}

export interface AudioCatalog {
  ready?: boolean;
  count: number;
  files: CatalogEntry[];
  errors: Array<{code: string; detail?: string}>;
}

export interface RuntimeStatus {
  hooksReady: boolean;
  recentCaptureEnabled: boolean;
  totalCaptured: number;
  droppedPending: number;
  voiceIndexReady: boolean;
  catalogReady: boolean;
  catalogCount: number;
  configSchema: number;
  mode: RuleMode;
  ruleCount: number;
  matched: number;
  submitted: number;
  suppressed: number;
  failed: number;
  groupDirectoriesReady: boolean;
  groupUnwritableCount: number;
  testPlaybackRequested: number;
  testPlaybackSubmitted: number;
  testPlaybackFailed: number;
}

export interface ControllerState {
  schemaVersion: number;
  revision: number;
  status: RuntimeStatus;
  events: AudioEvent[];
  catalog: AudioCatalog | null;
  config: ReplacementConfig | null;
  savedEvents: AudioEvent[];
  groupFolders: GroupFolderMeta[];
  conflicts: GroupConflict[];
  folderRejects: FolderReject[];
  unwritableFolders: UnwritableFolder[];
  warnings: string[];
  editor: {ready: boolean; dirty: boolean; lastError?: string};
}

// 目录名含非 ASCII 的分组：REFramework 的文件 API 按本机代码页解释路径，写清单只会生成乱码目录。
export interface UnwritableFolder {
  id: string;
  folder: string;
}

// Groups 文件夹的扫描元数据：文件夹就是分组，压缩整个文件夹即可分发。
export interface GroupFolderMeta {
  folder: string;
  name: string;
  version?: string | null;
  author?: string | null;
  description?: string | null;
  audioDirectory?: string;
  hasManifest: boolean;
  writable: boolean;
  registered: boolean;
  ruleCount: number;
  warnings: string[];
}

export interface GroupConflictEntry {
  group_id: string;
  group_name: string;
  rule_id: string;
  mode: string;
  enabled: boolean;
}

export interface GroupConflict {
  stableKey: string;
  actionKey?: string;
  matchKey?: string;
  winner: GroupConflictEntry | null;
  losers: GroupConflictEntry[];
}

export interface FolderReject {
  id: string;
  code: string;
}

export interface RuleRef {
  groupId: string;
  ruleId: string;
}

export interface CandidateRef extends RuleRef {
  candidateIndex: number;
}
