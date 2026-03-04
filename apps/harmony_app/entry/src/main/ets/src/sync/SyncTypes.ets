export enum SyncProviderType {
  NONE = 'none',
  WEBDAV = 'webdav',
  NAS_WEBDAV = 'nasWebdav',
  S3_PRESIGNED = 's3Presigned'
}

export enum ConflictStrategy {
  REMOTE_WINS = 'remoteWins',
  LOCAL_WINS = 'localWins',
  KEEP_BOTH = 'keepBoth'
}

export interface SyncLogEntry {
  timestamp: number;
  level: 'info' | 'error';
  message: string;
}

export interface SyncSettings {
  providerType: SyncProviderType;
  webdavUrl: string;
  webdavUsername: string;
  webdavPassword: string;
  webdavPath: string;
  presignedDownloadUrl: string;
  presignedUploadUrl: string;
  autoSyncEnabled: boolean;
  autoSyncIntervalMinutes: number;
  autoSyncOnUnlock: boolean;
  conflictStrategy: ConflictStrategy;
  syncMasterKey: boolean;
  deviceId: string;
  lastSyncRevision: number;
  lastSyncAt: number;
  lastSyncStatus: string;
  lastSyncMessage: string;
  logs: SyncLogEntry[];
}

export function defaultSyncSettings(): SyncSettings {
  return {
    providerType: SyncProviderType.NONE,
    webdavUrl: '',
    webdavUsername: '',
    webdavPassword: '',
    webdavPath: '/vault.json',
    presignedDownloadUrl: '',
    presignedUploadUrl: '',
    autoSyncEnabled: false,
    autoSyncIntervalMinutes: 30,
    autoSyncOnUnlock: true,
    conflictStrategy: ConflictStrategy.REMOTE_WINS,
    syncMasterKey: true,
    deviceId: generateDeviceId(),
    lastSyncRevision: 0,
    lastSyncAt: 0,
    lastSyncStatus: '',
    lastSyncMessage: '',
    logs: [],
  };
}

function generateDeviceId(): string {
  const ts = Date.now().toString(36);
  const rand = Math.floor(Math.random() * 1_000_000_000).toString(36);
  return `${ts}-${rand}`;
}
