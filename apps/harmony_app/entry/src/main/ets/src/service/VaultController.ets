import { Context } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import fs from '@ohos.file.fs';
import {
  CategorySyncState,
  CategoryTemplate,
  CategoryTypePreset,
  CreateCredentialInput,
  CreateServerInput,
  CreateServiceInput,
  CustomField,
  EncryptedPayloadRecord,
  FieldTemplate,
  MasterKeyRecord,
  SecuritySettings,
  ServiceAccount,
  UnlockGuardState,
  VaultEntry,
  VaultEntryType,
  VaultPayloadRecord,
  VaultPersistenceEnvelope,
} from '../model/VaultTypes';
import { VaultCryptoService } from '../security/VaultCryptoService';
import { TotpService } from '../security/TotpService';
import {
  ConflictStrategy,
  defaultSyncSettings,
  SyncLogEntry,
  SyncIntervalUnit,
  SyncProviderType,
  SyncSettings,
} from '../sync/SyncTypes';
import {
  ObjectStorageSyncClient,
  PresignedUrlSyncClient,
  RemoteSyncClient,
  WebDavSyncClient,
} from '../sync/RemoteSyncClient';
import { VaultStore } from '../storage/VaultStore';
import {
  EntryReferenceResolution,
  FieldValueReferenceResolution,
  propagateEntryReferenceCategoryRename,
  resolveEntryReference,
  resolveFieldValueReference,
  targetFieldReferenceIdsForCategory,
} from '../domain/FieldReferenceResolver';
import { categoryTemplateFieldsForUserSave } from '../domain/CategoryTemplateEditing';
import {
  remapEntryReferenceCustomFields,
  resolvedEntryReferenceSearchValues,
} from '../domain/EntryReferenceOperations';

interface VaultRuntimePayload extends VaultPayloadRecord {
  categoryTemplates: CategoryTemplate[];
  categoryStates: CategorySyncState[];
  security: SecuritySettings;
  syncSettings: SyncSettings;
}

interface SyncEnvelope {
  version: number;
  exportedAt: string;
  deviceId: string;
  revision: number;
  masterKeyRecord: MasterKeyRecord | null;
  encryptedVault: EncryptedPayloadRecord | null;
}

interface ExportSnapshotRecord {
  version: number;
  exportedAt: string;
  tags: string[];
  categories: string[];
  categoryTemplates: CategoryTemplate[];
  categoryStates: CategorySyncState[];
  entries: VaultEntry[];
  masterKeyRecord: MasterKeyRecord | null;
  security: SecuritySettings;
  syncSettings: SyncSettings;
}

interface ExportItemRecord {
  id: string;
  label: string;
  type: VaultEntryType;
  category: string;
  tags: string[];
  customFields: CustomField[];
  createdAt: string;
  updatedAt: string;
  payload: object;
}

interface ExportSingleItemRecord {
  version: number;
  scope: string;
  exportedAt: string;
  item: object;
  categoryTemplates: CategoryTemplate[];
}

interface ExportCategoryRecord {
  version: number;
  scope: string;
  exportedAt: string;
  category: string;
  count: number;
  items: ExportItemRecord[];
  categoryTemplates: CategoryTemplate[];
}

export interface BackupInfo {
  fileName: string;
  sizeBytes: number;
  modifiedAt: number;
}

interface SelectedExportItemRecord {
  id: string;
  type: VaultEntryType;
  label?: string;
  category?: string;
  tags?: string[];
  customFields?: CustomField[];
  createdAt?: string;
  updatedAt?: string;
  payload?: object;
}

interface ImportSingleItemRecord {
  version?: number;
  scope?: string;
  item?: ExportItemRecord;
  categoryTemplates?: CategoryTemplate[];
}

interface ImportCategoryRecord {
  version?: number;
  scope?: string;
  items?: ExportItemRecord[];
  categoryTemplates?: CategoryTemplate[];
}

interface DecodedScopedImportRecord {
  version: number;
  items: ExportItemRecord[];
  categoryTemplates: CategoryTemplate[];
}

export enum ImportConflictStrategy {
  SKIP = 'skip',
  OVERWRITE = 'overwrite',
  KEEP_COPY = 'keep_copy',
}

type ImportDisposition = 'create' | 'exactDuplicate' | 'conflict';

export interface ImportPreviewItemRecord {
  label: string;
  type: VaultEntryType;
  category: string;
  disposition: ImportDisposition;
  existingLabel?: string;
}

export interface ImportPreviewRecord {
  scope: string;
  totalCount: number;
  createCount: number;
  exactDuplicateCount: number;
  conflictCount: number;
  items: ImportPreviewItemRecord[];
}

export interface ImportExecutionResult {
  totalCount: number;
  createdCount: number;
  updatedCount: number;
  skippedCount: number;
}

interface ImportPlanItem {
  item: ExportItemRecord;
  disposition: ImportDisposition;
  existing?: VaultEntry;
}

interface ParsedSyncEnvelopeRecord {
  version?: number;
  exportedAt?: string;
  deviceId?: string;
  revision?: number;
  masterKeyRecord?: MasterKeyRecord | null;
  encryptedVault?: EncryptedPayloadRecord | null;
}

interface CategoryCarrier {
  category?: string;
  metadataCategory?: string;
}

interface TagsCarrier {
  tags?: string[];
  metadataTags?: string[];
}

interface EntryPayloadCarrier extends CategoryCarrier, TagsCarrier {}

interface EntryCarrier extends CategoryCarrier, TagsCarrier {
  id?: string;
  type?: VaultEntryType;
  payload?: EntryPayloadCarrier;
  customFields?: CustomField[];
  isDeleted?: boolean;
  deletedAt?: number;
  createdAt?: number;
  updatedAt?: number;
  label?: string;
}

interface AccessKeyCarrier {
  accessKey?: string;
  accessToken?: string;
}

interface AccountCarrier {
  accounts?: ServiceAccount[];
}

interface ServiceReferenceCarrier {
  accountId?: string;
  serverIds?: string[];
}

const MAX_UNLOCK_ATTEMPTS: number = 5;
const LOCKOUT_DURATION_MS: number = 5 * 60 * 1000;
const AUTO_SYNC_SYNCING_STATUS: string = '同步中';
const BACKUP_DIR_NAME: string = 'backups';
const BACKUP_RETAIN_COUNT: number = 5;
const BACKUP_FILE_PATTERN: RegExp = /^vault-\d{8}-\d{6}\.json$/;

export class VaultController {
  private static readonly SCHEMA_VERSION: number = 1;

  private readonly store: VaultStore;
  private readonly crypto: VaultCryptoService;
  private readonly syncContext: Context | null;
  private readonly totp: TotpService;
  private snapshot: VaultRuntimePayload = createEmptyPayload();
  private masterKeyRecord: MasterKeyRecord | null = null;
  private sessionKeyToken: string | null = null;
  private unlockGuard: UnlockGuardState = defaultUnlockGuardState();
  private lastUnlockError: string = '';
  private unlocked: boolean = false;
  private syncInProgress: boolean = false;
  private syncRequestedAgain: boolean = false;
  private localChangeRevision: number = 0;
  private lastAutoSyncAttemptAt: number = 0;

  constructor(store: VaultStore, crypto: VaultCryptoService, syncContext: Context | null = null) {
    this.store = store;
    this.crypto = crypto;
    this.syncContext = syncContext;
    this.totp = new TotpService();
  }

  async initialize(): Promise<void> {
    const envelope = await this.readEnvelope();
    this.masterKeyRecord = envelope.masterKeyRecord;
    this.unlockGuard = normalizeUnlockGuardState(envelope.unlockGuard);
    this.lastUnlockError = '';
    this.unlocked = false;
    this.sessionKeyToken = null;
    this.snapshot = createEmptyPayload();
  }

  hasMasterKey(): boolean {
    return this.masterKeyRecord !== null;
  }

  isUnlocked(): boolean {
    return this.unlocked;
  }

  isSyncing(): boolean {
    return this.syncInProgress;
  }

  getLastUnlockError(): string {
    return this.lastUnlockError;
  }

  getUnlockGuardState(): UnlockGuardState {
    return cloneUnlockGuardState(this.unlockGuard);
  }

  getLockRemainingSeconds(now: number = Date.now()): number {
    if (this.unlockGuard.lockUntil <= now) {
      return 0;
    }
    return Math.ceil((this.unlockGuard.lockUntil - now) / 1000);
  }

  getTags(): string[] {
    return [...this.snapshot.tags];
  }

  getCategories(): string[] {
    return [...this.snapshot.categories];
  }

  getCategoryTemplates(): CategoryTemplate[] {
    return this.snapshot.categoryTemplates.map((template: CategoryTemplate) =>
      cloneCategoryTemplate(template)
    );
  }

  categoryTemplateFieldHasStoredValue(category: string, templateFieldId: string): boolean {
    this.ensureUnlocked();
    return this.categoryTemplateFieldIdsWithStoredValues(category).has(templateFieldId) ||
      targetFieldReferenceIdsForCategory(
        this.snapshot.categoryTemplates,
        category,
      ).has(templateFieldId);
  }

  getEntries(): VaultEntry[] {
    const visible = this.snapshot.entries.filter(
      (entry: VaultEntry) => !entry.isDeleted,
    );
    visible.sort((a: VaultEntry, b: VaultEntry) => b.updatedAt - a.updatedAt);
    return visible.map((entry: VaultEntry) => deepCopyEntry(entry));
  }

  resolveEntryReferenceField(
    field: CustomField,
    category: string,
  ): EntryReferenceResolution | null {
    this.ensureUnlocked();
    const categoryKey = category.trim().toLowerCase();
    const template = this.snapshot.categoryTemplates.find(
      (candidate: CategoryTemplate) =>
        candidate.category.trim().toLowerCase() === categoryKey,
    ) ?? null;
    return resolveEntryReference(field, template, this.snapshot.entries);
  }

  resolveFieldValueReferenceField(
    sourceEntry: VaultEntry,
    field: CustomField,
  ): FieldValueReferenceResolution | null {
    this.ensureUnlocked();
    return resolveFieldValueReference(
      sourceEntry,
      field,
      this.snapshot.categoryTemplates,
      this.snapshot.entries,
    );
  }

  getSyncSettings(): SyncSettings {
    return cloneSyncSettings(this.snapshot.syncSettings);
  }

  getSecuritySettings(): SecuritySettings {
    this.ensureUnlocked();
    return cloneSecuritySettings(this.snapshot.security);
  }

  searchEntries(
    query: string,
    type: string = 'all',
    tag: string = '',
  ): VaultEntry[] {
    const q = query.trim().toLowerCase();
    const selectedTag = tag.trim().toLowerCase();
    return this.getEntries().filter((entry: VaultEntry) => {
      if (type !== 'all' && entry.type !== type) {
        return false;
      }
      if (selectedTag.length > 0) {
        const hitTag = entry.tags.some(
          (entryTag: string) => entryTag.toLowerCase() === selectedTag,
        );
        if (!hitTag) {
          return false;
        }
      }
      if (q.length === 0) {
        return true;
      }
      if (entry.label.toLowerCase().includes(q)) {
        return true;
      }
      if (entry.tags.some((entryTag: string) =>
        entryTag.toLowerCase().includes(q)
      )) {
        return true;
      }
      return resolvedEntryReferenceSearchValues(
        entry,
        this.snapshot.categoryTemplates,
        this.snapshot.entries,
      ).some((value: string) => value.toLowerCase().includes(q));
    });
  }

  async setupMasterPassword(password: string, confirm: string): Promise<boolean> {
    if (password.trim().length === 0 || password !== confirm) {
      return false;
    }

    const iterations = VaultCryptoService.DEFAULT_ITERATIONS;
    const saltBase64 = this.crypto.generateSaltBase64(16);
    const verifierBase64 = await this.crypto.deriveVerifier(
      password,
      saltBase64,
      iterations,
    );

    this.masterKeyRecord = {
      saltBase64,
      iterations,
      verifierBase64,
      metadataSaltBase64: saltBase64,
      metadataIterations: iterations,
    };
    this.sessionKeyToken = await this.crypto.deriveKeyToken(
      password,
      saltBase64,
      iterations,
    );
    this.unlocked = true;
    this.unlockGuard = defaultUnlockGuardState();
    this.lastUnlockError = '';

    this.snapshot = createEmptyPayload();
    await this.persist();
    return true;
  }

  async unlock(password: string, totpCode: string = ''): Promise<boolean> {
    const record = this.masterKeyRecord;
    if (record === null) {
      this.lastUnlockError = '主密码未初始化';
      return false;
    }

    const now = Date.now();
    if (this.unlockGuard.lockUntil > now) {
      const seconds = this.getLockRemainingSeconds(now);
      this.lastUnlockError = `解锁已被限制，请在 ${seconds} 秒后重试`;
      return false;
    }
    if (this.unlockGuard.lockUntil > 0 && this.unlockGuard.lockUntil <= now) {
      this.unlockGuard = defaultUnlockGuardState();
      await this.persistUnlockGuardOnly();
    }

    const verifier = await this.crypto.deriveVerifier(
      password,
      record.saltBase64,
      record.iterations,
    );
    if (verifier !== record.verifierBase64) {
      await this.onUnlockFailure('主密码错误');
      return false;
    }

    const sessionKey = await this.crypto.deriveKeyToken(
      password,
      record.metadataSaltBase64 ?? record.saltBase64,
      record.metadataIterations ?? record.iterations,
    );

    const envelope = await this.readEnvelope();
    let payload = createEmptyPayload();
    if (envelope.encryptedVault !== null) {
      try {
        const plaintext = await this.crypto.decryptString(
          envelope.encryptedVault,
          sessionKey,
        );
        payload = sanitizeRuntimePayload(
          JSON.parse(plaintext) as VaultPayloadRecord,
        );
      } catch (error) {
        console.error(`Decrypt vault payload failed: ${error}`);
        await this.onUnlockFailure('解锁失败');
        return false;
      }
    }

    if (payload.security.requireTotp) {
      const code = totpCode.trim();
      const verified = await this.totp.verifyCode(
        payload.security.totpSecret,
        code,
        now,
      );
      if (!verified) {
        await this.onUnlockFailure('动态验证码错误');
        return false;
      }
    }

    await this.resetUnlockGuard();
    this.snapshot = payload;
    this.sessionKeyToken = sessionKey;
    this.unlocked = true;
    this.lastUnlockError = '';

    if (
      this.snapshot.syncSettings.autoSyncEnabled &&
      this.snapshot.syncSettings.autoSyncOnUnlock
    ) {
      this.scheduleAutoSyncAfterUnlock();
    }

    return true;
  }

  async verifyMasterPassword(password: string): Promise<boolean> {
    const record = this.masterKeyRecord;
    if (record === null) {
      return false;
    }
    const verifier = await this.crypto.deriveVerifier(
      password,
      record.saltBase64,
      record.iterations,
    );
    return verifier === record.verifierBase64;
  }

  lock(): void {
    this.unlocked = false;
    this.sessionKeyToken = null;
    this.snapshot = createEmptyPayload();
    this.syncInProgress = false;
    this.lastAutoSyncAttemptAt = 0;
  }

  listBackups(): BackupInfo[] {
    const dir = this.backupDirectory();
    if (dir.length === 0 || !pathExists(dir)) {
      return [];
    }
    return fs.listFileSync(dir)
      .filter((fileName: string) => BACKUP_FILE_PATTERN.test(fileName))
      .map((fileName: string): BackupInfo => {
        const path = `${dir}/${fileName}`;
        const stat = fs.statSync(path);
        return {
          fileName,
          sizeBytes: stat.size,
          modifiedAt: stat.mtime * 1000,
        };
      })
      .sort((left: BackupInfo, right: BackupInfo) => right.fileName.localeCompare(left.fileName));
  }

  async runBackup(): Promise<BackupInfo> {
    this.ensureUnlocked();
    await this.persist(false);
    const dir = this.ensureBackupDirectory();
    const envelope = await this.readEnvelope();
    const fileName = `vault-${backupTimestamp()}.json`;
    const path = `${dir}/${fileName}`;
    this.writeTextFile(path, JSON.stringify(envelope));
    this.pruneBackups();
    const stat = fs.statSync(path);
    return {
      fileName,
      sizeBytes: stat.size,
      modifiedAt: stat.mtime * 1000,
    };
  }

  async restoreBackup(fileName: string): Promise<void> {
    this.ensureUnlocked();
    const sessionKey = this.sessionKeyToken;
    if (sessionKey === null) {
      throw new Error('Session key is missing');
    }
    const clean = fileName.trim();
    if (!BACKUP_FILE_PATTERN.test(clean)) {
      throw new Error('备份文件名无效');
    }
    const dir = this.backupDirectory();
    const path = `${dir}/${clean}`;
    if (dir.length === 0 || !pathExists(path)) {
      throw new Error('备份不存在');
    }
    const parsed = JSON.parse(fs.readTextSync(path)) as VaultPersistenceEnvelope;
    this.masterKeyRecord = parsed.masterKeyRecord ?? null;
    this.unlockGuard = normalizeUnlockGuardState(parsed.unlockGuard);
    if (parsed.encryptedVault === null || parsed.encryptedVault === undefined) {
      this.snapshot = createEmptyPayload();
    } else {
      try {
        const plaintext = await this.crypto.decryptString(parsed.encryptedVault, sessionKey);
        this.snapshot = sanitizeRuntimePayload(JSON.parse(plaintext) as VaultPayloadRecord);
      } catch (error) {
        throw new Error(`备份无法用当前主密码解密: ${error}`);
      }
    }
    await this.persist();
  }

  private backupDirectory(): string {
    if (this.syncContext === null) {
      return '';
    }
    return `${this.syncContext.filesDir}/${BACKUP_DIR_NAME}`;
  }

  private ensureBackupDirectory(): string {
    const dir = this.backupDirectory();
    if (dir.length === 0) {
      throw new Error('应用私有存储不可用');
    }
    if (!pathExists(dir)) {
      fs.mkdirSync(dir, true);
    }
    return dir;
  }

  private writeTextFile(path: string, contents: string): void {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(
        path,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC,
      );
      fs.writeSync(file.fd, contents, {
        encoding: 'utf-8',
      });
    } finally {
      if (file !== null) {
        fs.closeSync(file);
      }
    }
  }

  private pruneBackups(): void {
    const dir = this.backupDirectory();
    if (dir.length === 0 || !pathExists(dir)) {
      return;
    }
    const backups = this.listBackups();
    backups.slice(BACKUP_RETAIN_COUNT).forEach((backup: BackupInfo) => {
      try {
        fs.unlinkSync(`${dir}/${backup.fileName}`);
      } catch (error) {
        console.error(`Prune backup failed: ${error}`);
      }
    });
  }

  async updateSyncSettings(settings: SyncSettings): Promise<void> {
    this.ensureUnlocked();
    const normalized = normalizeSyncSettings(settings);
    normalized.hasLocalChanges = this.snapshot.syncSettings.hasLocalChanges;
    this.snapshot.syncSettings = normalized;
    await this.persist(false);
  }

  async updateSecuritySettings(settings: SecuritySettings): Promise<void> {
    this.ensureUnlocked();
    this.snapshot.security = normalizeSecuritySettings(settings);
    await this.persist();
  }

  async syncNow(): Promise<void> {
    this.ensureUnlocked();
    if (this.syncInProgress) {
      this.syncRequestedAgain = true;
      return;
    }

    this.syncInProgress = true;
    try {
      do {
        this.syncRequestedAgain = false;
        const localSettings = this.snapshot.syncSettings;
        if (localSettings.providerType === SyncProviderType.NONE) {
          this.recordSyncStatus('skipped', '未配置同步', localSettings.lastSyncRevision);
          await this.persist(false);
          return;
        }
        const client = this.buildSyncClient(localSettings);
        if (client === null) {
          this.recordSyncStatus('error', '同步配置不完整', localSettings.lastSyncRevision);
          await this.persist(false);
          return;
        }
        await this.performSyncOnce(client, localSettings);
      } while (this.syncRequestedAgain);
    } finally {
      this.syncInProgress = false;
    }
  }

  private async performSyncOnce(client: RemoteSyncClient, localSettings: SyncSettings): Promise<void> {
    const revisionAtStart = this.localChangeRevision;
    try {
      let mergedPayload = deepCopyRuntimePayload(this.snapshot);
      let remoteRevision = localSettings.lastSyncRevision;
      let mergedMasterKey = this.masterKeyRecord;
      let remoteFingerprint = '';

      try {
        const metadata = await client.metadata();
        remoteFingerprint = metadata.fingerprint;
        if (
          !localSettings.hasLocalChanges &&
          remoteFingerprint.length > 0 &&
          remoteFingerprint === localSettings.lastRemoteFingerprint &&
          isSuccessfulRemoteStatus(metadata.statusCode)
        ) {
          this.recordSyncStatus(
            'success',
            '远端未变化，已跳过完整同步下载',
            localSettings.lastSyncRevision,
            remoteFingerprint,
          );
          await this.persist(false);
          return;
        }
      } catch (error) {
        console.warn(`Remote metadata check failed, falling back to full sync: ${error}`);
      }

      const remote = await client.download();
      if (remote.statusCode === 404 || remote.statusCode === 204) {
        // No remote snapshot yet, upload local directly.
      } else if (remote.statusCode >= 200 && remote.statusCode < 300) {
        if (remote.payload.trim().length === 0) {
          // Remote exists but empty payload, treat as initial state.
          remoteRevision = localSettings.lastSyncRevision;
        } else {
          const remoteEnvelope = parseSyncEnvelope(remote.payload);
          remoteRevision = remoteEnvelope.revision;

          if (localSettings.hasLocalChanges && remoteRevision <= localSettings.lastSyncRevision) {
            const nextRevision = localSettings.lastSyncRevision + 1;
            const uploadPayload = sanitizeRuntimePayload(this.snapshot);
            uploadPayload.syncSettings = cloneSyncSettings(localSettings);
            uploadPayload.syncSettings.hasLocalChanges = false;
            uploadPayload.syncSettings.lastRemoteFingerprint = '';
            const payload = await this.buildSyncPayload(
              uploadPayload,
              nextRevision,
              uploadPayload.syncSettings,
              mergedMasterKey,
            );
            if (this.localRevisionChangedSince(revisionAtStart)) {
              this.syncRequestedAgain = true;
              return;
            }
            const upload = await client.upload(payload);
            if (this.localRevisionChangedSince(revisionAtStart)) {
              this.syncRequestedAgain = true;
              return;
            }
            if (upload.statusCode < 200 || upload.statusCode >= 300) {
              this.recordSyncStatus(
                'error',
                `上传失败(${upload.statusCode})`,
                localSettings.lastSyncRevision,
              );
              await this.persist(false);
              return;
            }
            if (this.localRevisionChangedSince(revisionAtStart)) {
              this.syncRequestedAgain = true;
              return;
            }
            this.snapshot = uploadPayload;
            const uploadedFingerprint = await this.safeRemoteFingerprint(client);
            this.recordSyncStatus(
              'success',
              `同步完成：修订${nextRevision}，条目${uploadPayload.entries.length}项`,
              nextRevision,
              uploadedFingerprint,
            );
            await this.persist(false);
            return;
          }

          if (
            localSettings.syncMasterKey &&
            remoteEnvelope.masterKeyRecord !== null
          ) {
            mergedMasterKey = remoteEnvelope.masterKeyRecord;
          }

          if (remoteEnvelope.encryptedVault !== null) {
            const sessionKey = this.sessionKeyToken;
            if (sessionKey === null) {
              throw new Error('Session key is missing');
            }
            const remotePlain = await this.crypto.decryptString(
              remoteEnvelope.encryptedVault,
              sessionKey,
            );
            const remotePayload = sanitizeRuntimePayload(
              JSON.parse(remotePlain) as VaultPayloadRecord,
            );
            mergedPayload = this.mergePayloads(
              mergedPayload,
              remotePayload,
              localSettings.conflictStrategy,
            );
          }
        }
      } else {
        this.recordSyncStatus(
          'error',
          `远端下载失败(${remote.statusCode})`,
          localSettings.lastSyncRevision,
        );
        await this.persist(false);
        return;
      }

      mergedPayload.syncSettings = cloneSyncSettings(localSettings);
      const uploadPayload = sanitizeRuntimePayload(mergedPayload);
      uploadPayload.syncSettings.hasLocalChanges = false;
      uploadPayload.syncSettings.lastRemoteFingerprint = '';
      const nextRevision =
        Math.max(localSettings.lastSyncRevision, remoteRevision) + 1;
      const payload = await this.buildSyncPayload(
        uploadPayload,
        nextRevision,
        uploadPayload.syncSettings,
        mergedMasterKey,
      );

      if (this.localRevisionChangedSince(revisionAtStart)) {
        this.syncRequestedAgain = true;
        return;
      }
      const upload = await client.upload(payload);
      if (this.localRevisionChangedSince(revisionAtStart)) {
        this.syncRequestedAgain = true;
        return;
      }
      if (upload.statusCode < 200 || upload.statusCode >= 300) {
        this.snapshot = mergedPayload;
        this.masterKeyRecord = mergedMasterKey;
        this.recordSyncStatus(
          'error',
          `上传失败(${upload.statusCode})`,
          localSettings.lastSyncRevision,
        );
        await this.persist(false);
        return;
      }

      if (this.localRevisionChangedSince(revisionAtStart)) {
        this.syncRequestedAgain = true;
        return;
      }
      this.snapshot = uploadPayload;
      this.masterKeyRecord = mergedMasterKey;
      const uploadedFingerprint = await this.safeRemoteFingerprint(client);
      this.recordSyncStatus(
        'success',
        `同步完成：修订${nextRevision}，条目${mergedPayload.entries.length}项`,
        nextRevision,
        uploadedFingerprint,
      );
      await this.persist(false);
    } catch (error) {
      this.recordSyncStatus(
        'error',
        `同步失败: ${error}`,
        this.snapshot.syncSettings.lastSyncRevision,
      );
      await this.persist(false);
    }
  }

  shouldRunAutoSync(now: number = Date.now()): boolean {
    if (!this.unlocked || this.syncInProgress) {
      return false;
    }

    const settings = this.snapshot.syncSettings;
    if (
      !settings.autoSyncEnabled ||
      settings.providerType === SyncProviderType.NONE ||
      settings.lastSyncStatus === AUTO_SYNC_SYNCING_STATUS
    ) {
      return false;
    }

    const reference = Math.max(this.lastAutoSyncAttemptAt, settings.lastSyncAt || 0);
    if (reference <= 0) {
      return true;
    }
    return now - reference >= autoSyncIntervalMillis(settings);
  }

  async runAutoSyncIfNeeded(now: number = Date.now()): Promise<boolean> {
    if (!this.shouldRunAutoSync(now)) {
      return false;
    }
    this.lastAutoSyncAttemptAt = now;
    await this.syncNow();
    return true;
  }

  async addCredential(input: CreateCredentialInput, entryId: string = nextId()): Promise<void> {
    this.ensureUnlocked();
    const now = Date.now();
    const tags = normalizeTags(input.tags);
    const customFields = normalizeCustomFields(input.customFields);
    this.snapshot.entries.push({
      id: entryId,
      label: input.label.trim(),
      type: VaultEntryType.CREDENTIAL,
      payload: {
        username: input.username,
        password: input.password,
        accounts: normalizeServiceAccounts(input.accounts),
        token: input.token,
        appId: input.appId,
        accessKey: input.accessKey,
        secretKey: input.secretKey,
        notes: input.notes,
        tags,
        category: input.category.trim(),
      },
      tags,
      customFields,
      createdAt: now,
      updatedAt: now,
      isDeleted: false,
    });
    this.mergeCategories([input.category.trim()]);
    this.mergeTags(tags);
    await this.persist();
  }

  async addServer(input: CreateServerInput, entryId: string = nextId()): Promise<void> {
    this.ensureUnlocked();
    const now = Date.now();
    const tags = normalizeTags(input.tags);
    const customFields = normalizeCustomFields(input.customFields);
    this.snapshot.entries.push({
      id: entryId,
      label: input.label.trim(),
      type: VaultEntryType.SERVER,
      payload: {
        name: input.name,
        ipAddress: input.ipAddress,
        port: input.port,
        username: input.username,
        password: input.password,
        accounts: normalizeServiceAccounts(input.accounts),
        basicConfig: input.basicConfig,
        operatingSystem: input.operatingSystem,
        location: input.location,
        notes: input.notes,
        tags,
        category: input.category.trim(),
      },
      tags,
      customFields,
      createdAt: now,
      updatedAt: now,
      isDeleted: false,
    });
    this.mergeCategories([input.category.trim()]);
    this.mergeTags(tags);
    await this.persist();
  }

  async addService(input: CreateServiceInput, entryId: string = nextId()): Promise<void> {
    this.ensureUnlocked();
    const now = Date.now();
    const tags = normalizeTags(input.tags);
    const customFields = normalizeCustomFields(input.customFields);
    this.snapshot.entries.push({
      id: entryId,
      label: input.label.trim(),
      type: VaultEntryType.SERVICE,
      payload: {
        name: input.name,
        connectionAddress: input.connectionAddress,
        connectionPort: input.connectionPort,
        accountId: canonicalIdString(input.accountId),
        serverIds: normalizeReferenceIds(input.serverIds),
        accounts: normalizeServiceAccounts(input.accounts),
        notes: input.notes,
        tags,
        category: input.category.trim(),
      },
      tags,
      customFields,
      createdAt: now,
      updatedAt: now,
      isDeleted: false,
    });
    this.mergeCategories([input.category.trim()]);
    this.mergeTags(tags);
    await this.persist();
  }

  async updateCredentialEntry(entryId: string, input: CreateCredentialInput): Promise<void> {
    this.ensureUnlocked();
    const target = this.requireVisibleEntry(entryId, VaultEntryType.CREDENTIAL);
    const tags = normalizeTags(input.tags);
    const customFields = normalizeCustomFields(input.customFields);
    target.label = input.label.trim();
    target.payload = {
      username: input.username,
      password: input.password,
      accounts: normalizeServiceAccounts(input.accounts),
      token: input.token,
      appId: input.appId,
      accessKey: input.accessKey,
      secretKey: input.secretKey,
      notes: input.notes,
      tags,
      category: input.category.trim(),
    };
    target.tags = tags;
    target.customFields = customFields;
    target.updatedAt = Date.now();
    this.mergeCategories([input.category.trim()]);
    this.mergeTags(tags);
    await this.persist();
  }

  async updateServerEntry(entryId: string, input: CreateServerInput): Promise<void> {
    this.ensureUnlocked();
    const target = this.requireVisibleEntry(entryId, VaultEntryType.SERVER);
    const tags = normalizeTags(input.tags);
    const customFields = normalizeCustomFields(input.customFields);
    target.label = input.label.trim();
    target.payload = {
      name: input.name,
      ipAddress: input.ipAddress,
      port: input.port,
      username: input.username,
      password: input.password,
      accounts: normalizeServiceAccounts(input.accounts),
      basicConfig: input.basicConfig,
      operatingSystem: input.operatingSystem,
      location: input.location,
      notes: input.notes,
      tags,
      category: input.category.trim(),
    };
    target.tags = tags;
    target.customFields = customFields;
    target.updatedAt = Date.now();
    this.mergeCategories([input.category.trim()]);
    this.mergeTags(tags);
    await this.persist();
  }

  async updateServiceEntry(entryId: string, input: CreateServiceInput): Promise<void> {
    this.ensureUnlocked();
    const target = this.requireVisibleEntry(entryId, VaultEntryType.SERVICE);
    const tags = normalizeTags(input.tags);
    const customFields = normalizeCustomFields(input.customFields);
    target.label = input.label.trim();
    target.payload = {
      name: input.name,
      connectionAddress: input.connectionAddress,
      connectionPort: input.connectionPort,
      accountId: canonicalIdString(input.accountId),
      serverIds: normalizeReferenceIds(input.serverIds),
      accounts: normalizeServiceAccounts(input.accounts),
      notes: input.notes,
      tags,
      category: input.category.trim(),
    };
    target.tags = tags;
    target.customFields = customFields;
    target.updatedAt = Date.now();
    this.mergeCategories([input.category.trim()]);
    this.mergeTags(tags);
    await this.persist();
  }

  async deleteEntry(entryId: string): Promise<void> {
    this.ensureUnlocked();
    const targetId = canonicalIdString(entryId);
    const target = this.snapshot.entries.find(
      (entry: VaultEntry) => canonicalIdString(entry.id) === targetId,
    );
    if (target === undefined) {
      return;
    }
    target.isDeleted = true;
    const now = Date.now();
    target.updatedAt = now;
    (target as EntryCarrier).deletedAt = now;
    await this.persist();
  }

  async clearAllData(password: string): Promise<boolean> {
    this.ensureUnlocked();
    const verified = await this.verifyMasterPassword(password);
    if (!verified) {
      return false;
    }
    const currentSyncSettings = cloneSyncSettings(this.snapshot.syncSettings);
    const existingStates = normalizeCategoryStates(
      this.snapshot.categoryStates,
      this.snapshot.categories,
      this.snapshot.categoryTemplates,
      this.snapshot.entries,
      this.snapshot.updatedAt,
    );
    const activeCategories = this.snapshot.categories.slice();
    this.snapshot = createEmptyPayload();
    this.snapshot.categoryStates = existingStates;
    const resetSyncSettings = defaultSyncSettings();
    resetSyncSettings.deviceId = currentSyncSettings.deviceId;
    resetSyncSettings.hasLocalChanges = true;
    this.snapshot.syncSettings = resetSyncSettings;
    const now = Date.now();
    activeCategories.forEach((category: string) =>
      this.recordCategoryMutation(category, true, now)
    );
    await this.persist();
    return true;
  }

  async addTag(tag: string): Promise<void> {
    this.ensureUnlocked();
    const clean = tag.trim();
    if (clean.length === 0 || this.snapshot.tags.includes(clean)) {
      return;
    }
    this.snapshot.tags.push(clean);
    this.snapshot.tags.sort((a: string, b: string) => a.localeCompare(b));
    await this.persist();
  }

  async addCategory(category: string, customFieldNames: string[] = []): Promise<void> {
    this.ensureUnlocked();
    const clean = category.trim();
    if (clean.length === 0 || this.snapshot.categories.includes(clean)) {
      return;
    }
    this.snapshot.categories.push(clean);
    this.snapshot.categories.sort((a: string, b: string) => a.localeCompare(b));
    this.recordCategoryMutation(clean, false, Date.now());
    this.upsertCategoryTemplate(clean, fieldsForCategoryPreset('', customFieldNames));
    await this.persist();
  }

  async addCategoryWithTemplateFields(
    category: string,
    customFields: FieldTemplate[],
  ): Promise<void> {
    this.ensureUnlocked();
    const clean = category.trim();
    if (
      clean.length === 0 ||
      this.snapshot.categories.some(
        (existing: string) => existing.trim().toLowerCase() === clean.toLowerCase(),
      )
    ) {
      return;
    }
    this.snapshot.categories.push(clean);
    this.snapshot.categories.sort((a: string, b: string) => a.localeCompare(b));
    this.recordCategoryMutation(clean, false, Date.now());
    this.upsertCategoryTemplate(
      clean,
      categoryTemplateFieldsForUserSave([], customFields),
    );
    await this.persist();
  }

  async applyCategoryPreset(
    category: string,
    preset: CategoryTypePreset,
    customFieldNames: string[] = [],
  ): Promise<void> {
    this.ensureUnlocked();
    const clean = category.trim();
    if (clean.length === 0) {
      return;
    }
    this.mergeCategories([clean]);
    const existing = this.snapshot.categoryTemplates.find(
      (template: CategoryTemplate) => template.category.toLowerCase() === clean.toLowerCase(),
    );
    this.upsertCategoryTemplate(
      clean,
      mergeEditableTemplateFields(
        existing?.fields ?? [],
        fieldsForCategoryPreset(preset, customFieldNames),
      ),
    );
    await this.persist();
  }

  async saveCategoryTemplate(category: string, customFieldNames: string[] = []): Promise<void> {
    this.ensureUnlocked();
    const clean = category.trim();
    if (clean.length === 0) {
      return;
    }
    this.mergeCategories([clean]);
    const existing = this.snapshot.categoryTemplates.find(
      (template: CategoryTemplate) => template.category.toLowerCase() === clean.toLowerCase(),
    );
    this.upsertCategoryTemplate(
      clean,
      mergeEditableTemplateFields(
        existing?.fields ?? [],
        fieldsForCategoryPreset('', customFieldNames),
      ),
    );
    await this.persist();
  }

  async saveCategoryTemplateFields(
    category: string,
    customFields: FieldTemplate[],
  ): Promise<void> {
    this.ensureUnlocked();
    const clean = category.trim();
    if (clean.length === 0) {
      return;
    }
    this.mergeCategories([clean]);
    const existing = this.snapshot.categoryTemplates.find(
      (template: CategoryTemplate) =>
        template.category.trim().toLowerCase() === clean.toLowerCase(),
    );
    const storedValueFieldIds = this.categoryTemplateFieldIdsWithStoredValues(clean);
    targetFieldReferenceIdsForCategory(
      this.snapshot.categoryTemplates,
      clean,
    ).forEach((fieldId: string) => storedValueFieldIds.add(fieldId));
    this.upsertCategoryTemplate(
      clean,
      categoryTemplateFieldsForUserSave(
        existing?.fields ?? [],
        customFields,
        storedValueFieldIds,
      ),
    );
    await this.persist();
  }

  async renameTag(oldTag: string, newTag: string): Promise<void> {
    this.ensureUnlocked();
    const from = oldTag.trim();
    const to = newTag.trim();
    if (from.length === 0 || to.length === 0 || from === to) {
      return;
    }
    this.snapshot.tags = this.snapshot.tags.map((entryTag: string) =>
      entryTag === from ? to : entryTag,
    );
    this.snapshot.tags = normalizeTags(this.snapshot.tags);
    this.snapshot.entries.forEach((entry: VaultEntry) => {
      if (entry.isDeleted) {
        return;
      }
      entry.tags = normalizeTags(
        entry.tags.map((entryTag: string) => (entryTag === from ? to : entryTag)),
      );
      entry.updatedAt = Date.now();
    });
    await this.persist();
  }

  async deleteTag(tag: string): Promise<void> {
    this.ensureUnlocked();
    const clean = tag.trim();
    this.snapshot.tags = this.snapshot.tags.filter(
      (entryTag: string) => entryTag !== clean,
    );
    this.snapshot.entries.forEach((entry: VaultEntry) => {
      if (entry.isDeleted) {
        return;
      }
      entry.tags = entry.tags.filter((entryTag: string) => entryTag !== clean);
      entry.updatedAt = Date.now();
    });
    await this.persist();
  }

  async renameCategory(oldCategory: string, newCategory: string): Promise<void> {
    this.ensureUnlocked();
    const from = oldCategory.trim();
    const to = newCategory.trim();
    if (from.length === 0 || to.length === 0 || from === to) {
      return;
    }
    this.snapshot.categories = this.snapshot.categories.map((entryCategory: string) =>
      entryCategory === from ? to : entryCategory,
    );
    this.snapshot.categories = normalizeTags(this.snapshot.categories);
    const now = Date.now();
    this.recordCategoryMutation(from, true, now);
    this.recordCategoryMutation(to, false, now);
    this.snapshot.categoryTemplates = this.snapshot.categoryTemplates.map((template: CategoryTemplate) => {
      if (template.category !== from) {
        return template;
      }
      return normalizeCategoryTemplate({
        category: to,
        fields: template.fields,
      });
    });
    this.snapshot.categoryTemplates = propagateEntryReferenceCategoryRename(
      this.snapshot.categoryTemplates,
      from,
      to,
    );
    this.snapshot.entries.forEach((entry: VaultEntry) => {
      if (entry.isDeleted) {
        return;
      }
      const category = this.entryCategory(entry);
      if (category !== from) {
        return;
      }
      this.setEntryCategory(entry, to);
      entry.updatedAt = now;
    });
    await this.persist();
  }

  async deleteCategory(category: string): Promise<void> {
    this.ensureUnlocked();
    const clean = category.trim();
    const now = Date.now();
    this.snapshot.categories = this.snapshot.categories.filter(
      (entryCategory: string) => entryCategory !== clean,
    );
    this.snapshot.categoryTemplates = this.snapshot.categoryTemplates.filter(
      (template: CategoryTemplate) => template.category !== clean,
    );
    this.snapshot.entries.forEach((entry: VaultEntry) => {
      if (entry.isDeleted) {
        return;
      }
      if (this.entryCategory(entry) !== clean) {
        return;
      }
      this.setEntryCategory(entry, '');
      entry.updatedAt = now;
    });
    this.recordCategoryMutation(clean, true, now);
    await this.persist();
  }

  exportSnapshot(): string {
    this.ensureUnlocked();
    const snapshot = sanitizeRuntimePayload(this.snapshot);
    const payload: ExportSnapshotRecord = {
      version: VaultController.SCHEMA_VERSION,
      exportedAt: new Date().toISOString(),
      tags: snapshot.tags,
      categories: snapshot.categories,
      categoryTemplates: snapshot.categoryTemplates,
      categoryStates: snapshot.categoryStates,
      entries: snapshot.entries,
      masterKeyRecord: this.masterKeyRecord,
      security: snapshot.security,
      syncSettings: snapshot.syncSettings,
    };
    return JSON.stringify(payload, null, 2);
  }

  exportEntryData(entryId: string, selectedFieldIds: string[] | null = null): string {
    this.ensureUnlocked();
    const targetId = canonicalIdString(entryId);
    const entry = this.snapshot.entries.find(
      (value: VaultEntry) => canonicalIdString(value.id) === targetId && !value.isDeleted,
    );
    if (entry === undefined) {
      throw new Error('条目不存在或已删除');
    }
    const item = selectedFieldIds === null
      ? this.buildExportItem(entry)
      : this.buildSelectedExportItem(entry, selectedFieldIds);
    const payload = createScopedItemExportRecord(
      item,
      categoryTemplatesForExport(this.snapshot.categoryTemplates, [this.entryCategory(entry)]),
      new Date().toISOString(),
    );
    return JSON.stringify(payload, null, 2);
  }

  exportCategoryData(category: string): string {
    this.ensureUnlocked();
    const clean = category.trim();
    const items = this.snapshot.entries
      .filter((entry: VaultEntry) => !entry.isDeleted && this.entryCategory(entry) === clean)
      .map((entry: VaultEntry) => this.buildExportItem(entry))
      .sort(
        (left: ExportItemRecord, right: ExportItemRecord) => left.label.localeCompare(right.label),
      );
    const payload = createScopedCategoryExportRecord(
      clean,
      items,
      categoryTemplatesForExport(this.snapshot.categoryTemplates, [clean]),
      new Date().toISOString(),
    );
    return JSON.stringify(payload, null, 2);
  }

  async importEntryData(contents: string): Promise<number> {
    const result = await this.applyScopedImport(
      contents,
      'item',
      ImportConflictStrategy.KEEP_COPY,
    );
    return result.createdCount + result.updatedCount;
  }

  async importCategoryData(contents: string): Promise<number> {
    const result = await this.applyScopedImport(
      contents,
      'category',
      ImportConflictStrategy.KEEP_COPY,
    );
    return result.createdCount + result.updatedCount;
  }

  async previewImportEntryData(contents: string): Promise<ImportPreviewRecord> {
    return this.toImportPreview(await this.buildImportPlan(contents, 'item'));
  }

  async previewImportCategoryData(contents: string): Promise<ImportPreviewRecord> {
    return this.toImportPreview(await this.buildImportPlan(contents, 'category'));
  }

  async importEntryDataWithStrategy(
    contents: string,
    strategy: ImportConflictStrategy,
  ): Promise<ImportExecutionResult> {
    return this.applyScopedImport(contents, 'item', strategy);
  }

  async importCategoryDataWithStrategy(
    contents: string,
    strategy: ImportConflictStrategy,
  ): Promise<ImportExecutionResult> {
    return this.applyScopedImport(contents, 'category', strategy);
  }

  private ensureUnlocked(): void {
    if (!this.unlocked || this.sessionKeyToken === null) {
      throw new Error('Vault is locked');
    }
  }

  private mergeTags(tags: string[]): void {
    const union = new Set<string>(this.snapshot.tags);
    tags.forEach((tag: string) => union.add(tag));
    const mergedTags = setToArray(union);
    mergedTags.sort((a: string, b: string) => a.localeCompare(b));
    this.snapshot.tags = mergedTags;
  }

  private mergeCategories(categories: string[]): void {
    const union = new Set<string>(this.snapshot.categories);
    const normalized = categories
      .map((category: string) => category.trim())
      .filter((category: string) => category.length > 0);
    const now = Date.now();
    normalized.forEach((category: string) => {
      union.add(category);
      this.ensureCategoryIsActive(category, now);
    });
    const mergedCategories = setToArray(union);
    mergedCategories.sort((a: string, b: string) => a.localeCompare(b));
    this.snapshot.categories = mergedCategories;
  }

  private ensureCategoryIsActive(category: string, updatedAt: number): void {
    const clean = category.trim();
    if (clean.length === 0) {
      return;
    }
    const existing = this.snapshot.categoryStates.find(
      (state: CategorySyncState) => state.name.trim().toLowerCase() === clean.toLowerCase(),
    );
    if (existing === undefined || existing.isDeleted) {
      this.recordCategoryMutation(clean, false, updatedAt);
    }
  }

  private recordCategoryMutation(category: string, isDeleted: boolean, updatedAt: number): void {
    const clean = category.trim();
    if (clean.length === 0) {
      return;
    }
    this.snapshot.categoryStates = normalizeCategoryStates(
      this.snapshot.categoryStates,
      this.snapshot.categories,
      this.snapshot.categoryTemplates,
      this.snapshot.entries,
      this.snapshot.updatedAt,
    );
    const key = clean.toLowerCase();
    const stateIndex = this.snapshot.categoryStates.findIndex(
      (state: CategorySyncState) => state.name.trim().toLowerCase() === key,
    );
    const existing = stateIndex >= 0 ? this.snapshot.categoryStates[stateIndex] : undefined;
    const updater = this.snapshot.syncSettings.deviceId.trim().length > 0
      ? this.snapshot.syncSettings.deviceId
      : 'harmony-native';
    const version = cloneCategoryVersion(existing?.version);
    version[updater] = (version[updater] ?? 0) + 1;
    const next: CategorySyncState = {
      name: clean,
      isDeleted,
      updatedAt,
      version,
      updatedBy: updater,
    };
    if (stateIndex >= 0) {
      this.snapshot.categoryStates[stateIndex] = next;
    } else {
      this.snapshot.categoryStates.push(next);
    }
  }

  private upsertCategoryTemplate(category: string, fields: FieldTemplate[]): void {
    const template = normalizeCategoryTemplate({
      category,
      fields: fields.map((field: FieldTemplate) => {
        const templateField: FieldTemplate = {
          id: field.id,
          name: field.name,
          valueType: normalizeFieldValueType(field.valueType),
          targetCategory: readPreservedString(field.targetCategory),
          targetFieldId: readPreservedString(field.targetFieldId),
        };
        return templateField;
      }),
    });
    const existingIndex = this.snapshot.categoryTemplates.findIndex(
      (entry: CategoryTemplate) => entry.category.toLowerCase() === template.category.toLowerCase(),
    );
    if (existingIndex >= 0) {
      this.snapshot.categoryTemplates[existingIndex] = template;
    } else {
      this.snapshot.categoryTemplates.push(template);
    }
    this.snapshot.categoryTemplates.sort((a: CategoryTemplate, b: CategoryTemplate) =>
      a.category.localeCompare(b.category));
  }

  private async applyScopedImport(
    contents: string,
    scope: string,
    strategy: ImportConflictStrategy,
  ): Promise<ImportExecutionResult> {
    const decoded = decodeScopedImportRecord(contents, scope);
    const plan = await this.buildImportPlan(contents, scope);
    const templatesChanged = this.mergeImportedCategoryTemplates(decoded.categoryTemplates);
    const result = await this.applyImportPlan(plan, strategy);
    if (templatesChanged) {
      await this.persist();
    }
    return result;
  }

  private mergeImportedCategoryTemplates(importedTemplates: CategoryTemplate[]): boolean {
    const previousCategories = JSON.stringify(this.snapshot.categories);
    const previousTemplates = JSON.stringify(this.snapshot.categoryTemplates);
    this.mergeCategories(
      importedTemplates.map((template: CategoryTemplate) => template.category),
    );
    this.snapshot.categoryTemplates = mergeImportedCategoryTemplateDefinitions(
      this.snapshot.categoryTemplates,
      importedTemplates,
    );
    return previousCategories !== JSON.stringify(this.snapshot.categories) ||
      previousTemplates !== JSON.stringify(this.snapshot.categoryTemplates);
  }

  private entryCategory(entry: VaultEntry): string {
    return resolveEntryCategory(entry);
  }

  private categoryTemplateFieldIdsWithStoredValues(category: string): Set<string> {
    const categoryKey = category.trim().toLowerCase();
    const ids = new Set<string>();
    const template = this.snapshot.categoryTemplates.find(
      (candidate: CategoryTemplate) =>
        candidate.category.trim().toLowerCase() === categoryKey,
    );
    if (template === undefined) {
      return ids;
    }
    const templateFieldIds = new Set<string>();
    template.fields.forEach((field: FieldTemplate) => {
      if (field.id.length > 0) {
        templateFieldIds.add(field.id);
      }
    });
    this.snapshot.entries.forEach((entry: VaultEntry) => {
      entry.customFields.forEach((field: CustomField) => {
        if (
          typeof field.templateFieldId === 'string' &&
          field.templateFieldId.length > 0 &&
          templateFieldIds.has(field.templateFieldId) &&
          field.value.length > 0
        ) {
          ids.add(field.templateFieldId);
        }
      });
    });
    return ids;
  }

  private scheduleAutoSyncAfterUnlock(): void {
    this.lastAutoSyncAttemptAt = Date.now();
    this.syncNow().catch(() => {
      console.error('Auto sync after unlock failed');
    });
  }

  private async safeRemoteFingerprint(client: RemoteSyncClient): Promise<string> {
    try {
      const metadata = await client.metadata();
      if (isSuccessfulRemoteStatus(metadata.statusCode)) {
        return metadata.fingerprint;
      }
    } catch (error) {
      console.warn(`Remote metadata refresh failed: ${error}`);
    }
    return '';
  }

  private buildExportItem(entry: VaultEntry): ExportItemRecord {
    const normalized = normalizeRuntimeEntry(entry);
    return {
      id: normalized.id,
      label: normalized.label,
      type: normalized.type,
      category: this.entryCategory(normalized),
      tags: [...normalized.tags],
      customFields: normalizeCustomFields(normalized.customFields),
      createdAt: new Date(normalized.createdAt).toISOString(),
      updatedAt: new Date(normalized.updatedAt).toISOString(),
      payload: JSON.parse(JSON.stringify(normalized.payload)) as object,
    };
  }

  private buildSelectedExportItem(entry: VaultEntry, selectedFieldIds: string[]): object {
    const normalized = normalizeRuntimeEntry(entry);
    const selected = new Set<string>(selectedFieldIds);
    const item = JSON.parse('{}') as SelectedExportItemRecord;
    item.id = normalized.id;
    item.type = normalized.type;
    if (selected.has('label')) {
      item.label = normalized.label;
    }
    if (selected.has('category')) {
      item.category = this.entryCategory(normalized);
    }
    if (selected.has('tags')) {
      item.tags = [...normalized.tags];
    }
    if (selected.has('createdAt')) {
      item.createdAt = new Date(normalized.createdAt).toISOString();
    }
    if (selected.has('updatedAt')) {
      item.updatedAt = new Date(normalized.updatedAt).toISOString();
    }

    const payload = JSON.parse(JSON.stringify(normalized.payload)) as Record<string, Object>;
    const selectedPayload = JSON.parse('{}') as Record<string, Object>;
    Object.keys(payload).forEach((key: string) => {
      if (selected.has(`payload.${key}`)) {
        selectedPayload[key] = payload[key];
      }
    });
    if (Object.keys(selectedPayload).length > 0) {
      item.payload = selectedPayload;
    }

    const customFields = normalizeCustomFields(normalized.customFields)
      .filter((field: CustomField) => selected.has(`custom.${field.id}`));
    if (customFields.length > 0) {
      item.customFields = customFields;
    }
    return item as object;
  }

  private async buildImportPlan(contents: string, scope: string): Promise<ImportPlanItem[]> {
    this.ensureUnlocked();
    const parsedItems = this.parseImportItems(contents, scope);
    const previewIdMap = new Map<string, string>();
    const planItems: ImportPlanItem[] = [];

    const appendPlanItem = (item: ExportItemRecord): void => {
      const existing = this.findImportTarget(item);
      const disposition: ImportDisposition =
        existing === undefined
          ? 'create'
          : this.importPayloadEquals(existing, item, previewIdMap)
            ? 'exactDuplicate'
            : 'conflict';
      if (existing !== undefined && item.id.length > 0) {
        previewIdMap.set(canonicalIdString(item.id), canonicalIdString(existing.id));
      }
      planItems.push({ item, disposition, existing });
    };

    parsedItems
      .filter((item: ExportItemRecord) => item.type !== VaultEntryType.SERVICE)
      .forEach((item: ExportItemRecord) => appendPlanItem(item));
    parsedItems
      .filter((item: ExportItemRecord) => item.type === VaultEntryType.SERVICE)
      .forEach((item: ExportItemRecord) => appendPlanItem(item));

    return planItems;
  }

  private toImportPreview(items: ImportPlanItem[]): ImportPreviewRecord {
    const previewItems = items.map((entry: ImportPlanItem) => {
      const previewItem: ImportPreviewItemRecord = {
        label: entry.item.label,
        type: entry.item.type,
        category: entry.item.category,
        disposition: entry.disposition,
        existingLabel: entry.existing?.label,
      };
      return previewItem;
    });
    const createCount = previewItems.filter((item: ImportPreviewItemRecord) => item.disposition === 'create').length;
    const exactDuplicateCount = previewItems
      .filter((item: ImportPreviewItemRecord) => item.disposition === 'exactDuplicate')
      .length;
    const conflictCount = previewItems
      .filter((item: ImportPreviewItemRecord) => item.disposition === 'conflict')
      .length;
    return {
      scope: items.length > 1 ? 'category' : 'item',
      totalCount: items.length,
      createCount,
      exactDuplicateCount,
      conflictCount,
      items: previewItems,
    };
  }

  private async applyImportPlan(
    items: ImportPlanItem[],
    strategy: ImportConflictStrategy,
  ): Promise<ImportExecutionResult> {
    let createdCount = 0;
    let updatedCount = 0;
    let skippedCount = 0;
    const idMap = new Map<string, string>();
    const destinationIds = items.map((current: ImportPlanItem) => {
      const createsCopy = current.disposition === 'create' ||
        (current.disposition === 'conflict' && strategy === ImportConflictStrategy.KEEP_COPY);
      const destinationId = createsCopy
        ? nextId()
        : canonicalIdString(current.existing?.id);
      if (current.item.id.length > 0 && destinationId.length > 0) {
        idMap.set(canonicalIdString(current.item.id), destinationId);
      }
      return destinationId;
    });
    for (let index = 0; index < items.length; index++) {
      const current = items[index];
      const destinationId = destinationIds[index];
      if (current.disposition === 'create') {
        await this.createImportedItem(current.item, idMap, destinationId);
        createdCount += 1;
        continue;
      }
      if (current.disposition === 'exactDuplicate') {
        skippedCount += 1;
        continue;
      }
      if (strategy === ImportConflictStrategy.SKIP) {
        skippedCount += 1;
        continue;
      }
      if (strategy === ImportConflictStrategy.OVERWRITE && current.existing !== undefined) {
        await this.updateImportedItem(current.existing, current.item, idMap);
        updatedCount += 1;
        continue;
      }
      await this.createImportedItem(current.item, idMap, destinationId);
      createdCount += 1;
    }
    return {
      totalCount: items.length,
      createdCount,
      updatedCount,
      skippedCount,
    };
  }

  private parseImportItems(contents: string, scope: string): ExportItemRecord[] {
    return decodeScopedImportRecord(contents, scope).items
      .map((item: ExportItemRecord) => normalizeExportItem(item));
  }

  private findImportTarget(item: ExportItemRecord): VaultEntry | undefined {
    const incomingId = canonicalIdString(item.id);
    if (incomingId.length > 0) {
      const byId = this.snapshot.entries.find(
        (entry: VaultEntry) =>
          !entry.isDeleted &&
          entry.type === item.type &&
          canonicalIdString(entry.id) === incomingId,
      );
      if (byId !== undefined) {
        return byId;
      }
    }
    const label = item.label.trim().toLowerCase();
    const category = item.category.trim().toLowerCase();
    let fallback: VaultEntry | undefined = undefined;
    for (let index = 0; index < this.snapshot.entries.length; index++) {
      const entry = this.snapshot.entries[index];
      if (entry.isDeleted || entry.type !== item.type || entry.label.trim().toLowerCase() !== label) {
        continue;
      }
      if (fallback === undefined) {
        fallback = entry;
      }
      if (this.entryCategory(entry).toLowerCase() === category) {
        return entry;
      }
    }
    return fallback;
  }

  private importPayloadEquals(
    existing: VaultEntry,
    item: ExportItemRecord,
    idMap: Map<string, string>,
  ): boolean {
    const normalizedIncoming = JSON.stringify({
      payload: this.resolveImportedPayload(item, idMap),
      customFields: normalizeCustomFields(item.customFields),
    });
    const normalizedExisting = JSON.stringify({
      payload: existing.payload,
      customFields: normalizeCustomFields(existing.customFields),
    });
    return normalizedIncoming === normalizedExisting;
  }

  private async createImportedItem(
    item: ExportItemRecord,
    idMap: Map<string, string> = new Map<string, string>(),
    destinationId: string = nextId(),
  ): Promise<string> {
    const customFields = remapEntryReferenceCustomFields(
      item.customFields,
      item.category,
      this.snapshot.categoryTemplates,
      idMap,
    );
    if (item.type === VaultEntryType.CREDENTIAL) {
      const payload = item.payload as CreateCredentialInput;
      await this.addCredential({
        label: item.label,
        username: payload.username ?? '',
        password: payload.password ?? '',
        accounts: normalizeServiceAccounts(payload.accounts),
        token: payload.token ?? '',
        appId: payload.appId ?? '',
        accessKey: resolveAccessKey(payload as AccessKeyCarrier),
        secretKey: payload.secretKey ?? '',
        notes: payload.notes ?? '',
        tags: payload.tags ?? [],
        category: payload.category ?? item.category ?? '',
        customFields,
      }, destinationId);
      return destinationId;
    }
    if (item.type === VaultEntryType.SERVER) {
      const payload = item.payload as CreateServerInput;
      await this.addServer({
        label: item.label,
        name: payload.name ?? '',
        ipAddress: payload.ipAddress ?? '',
        port: payload.port ?? '',
        username: payload.username ?? '',
        password: payload.password ?? '',
        accounts: normalizeServiceAccounts(payload.accounts),
        basicConfig: payload.basicConfig ?? '',
        operatingSystem: payload.operatingSystem ?? '',
        location: payload.location ?? '',
        notes: payload.notes ?? '',
        tags: payload.tags ?? [],
        category: payload.category ?? item.category ?? '',
        customFields,
      }, destinationId);
      return destinationId;
    }
    if (item.type === VaultEntryType.SERVICE) {
      const payload = item.payload as CreateServiceInput;
      await this.addService({
        label: item.label,
        name: payload.name ?? '',
        connectionAddress: payload.connectionAddress ?? '',
        connectionPort: payload.connectionPort ?? '',
        accountId: mappedReferenceId(idMap, payload.accountId),
        serverIds: (payload.serverIds ?? []).map(
          (entryId: string) => mappedReferenceId(idMap, entryId),
        ),
        accounts: normalizeServiceAccounts(payload.accounts),
        notes: payload.notes ?? '',
        tags: payload.tags ?? [],
        category: payload.category ?? item.category ?? '',
        customFields,
      }, destinationId);
      return destinationId;
    }
    throw new Error(`不支持的条目类型: ${item.type}`);
  }

  private async updateImportedItem(
    existing: VaultEntry,
    item: ExportItemRecord,
    idMap: Map<string, string>,
  ): Promise<void> {
    const resolved = this.resolveImportedPayload(item, idMap);
    const customFields = remapEntryReferenceCustomFields(
      item.customFields,
      item.category,
      this.snapshot.categoryTemplates,
      idMap,
    );
    if (existing.type === VaultEntryType.CREDENTIAL) {
      const payload = resolved as CreateCredentialInput;
      await this.updateCredentialEntry(existing.id, {
        label: item.label,
        username: payload.username ?? '',
        password: payload.password ?? '',
        accounts: normalizeServiceAccounts(payload.accounts),
        token: payload.token ?? '',
        appId: payload.appId ?? '',
        accessKey: resolveAccessKey(payload as AccessKeyCarrier),
        secretKey: payload.secretKey ?? '',
        notes: payload.notes ?? '',
        tags: payload.tags ?? [],
        category: payload.category ?? item.category ?? '',
        customFields,
      });
      return;
    }
    if (existing.type === VaultEntryType.SERVER) {
      const payload = resolved as CreateServerInput;
      await this.updateServerEntry(existing.id, {
        label: item.label,
        name: payload.name ?? '',
        ipAddress: payload.ipAddress ?? '',
        port: payload.port ?? '',
        username: payload.username ?? '',
        password: payload.password ?? '',
        accounts: normalizeServiceAccounts(payload.accounts),
        basicConfig: payload.basicConfig ?? '',
        operatingSystem: payload.operatingSystem ?? '',
        location: payload.location ?? '',
        notes: payload.notes ?? '',
        tags: payload.tags ?? [],
        category: payload.category ?? item.category ?? '',
        customFields,
      });
      return;
    }
    const payload = resolved as CreateServiceInput;
    await this.updateServiceEntry(existing.id, {
      label: item.label,
      name: payload.name ?? '',
      connectionAddress: payload.connectionAddress ?? '',
      connectionPort: payload.connectionPort ?? '',
      accountId: payload.accountId ?? '',
      serverIds: payload.serverIds ?? [],
      accounts: normalizeServiceAccounts(payload.accounts),
      notes: payload.notes ?? '',
      tags: payload.tags ?? [],
      category: payload.category ?? item.category ?? '',
      customFields,
    });
  }

  private resolveImportedPayload(
    item: ExportItemRecord,
    idMap: Map<string, string>,
  ): object {
    if (item.type !== VaultEntryType.SERVICE) {
      return JSON.parse(JSON.stringify(item.payload)) as object;
    }
    const payload = JSON.parse(JSON.stringify(item.payload)) as CreateServiceInput;
    payload.accountId = mappedReferenceId(idMap, payload.accountId);
    payload.serverIds = (payload.serverIds ?? []).map(
      (entryId: string) => mappedReferenceId(idMap, entryId),
    );
    return payload as object;
  }

  private requireVisibleEntry(entryId: string, type: VaultEntryType): VaultEntry {
    const targetId = canonicalIdString(entryId);
    const target = this.snapshot.entries.find(
      (entry: VaultEntry) =>
        canonicalIdString(entry.id) === targetId && !entry.isDeleted && entry.type === type,
    );
    if (target === undefined) {
      throw new Error('条目不存在或类型不匹配');
    }
    return target;
  }

  private setEntryCategory(entry: VaultEntry, category: string): void {
    const clean = category.trim();
    const payload = entry.payload as CategoryCarrier;
    payload.category = clean;
  }

  private async persist(markLocalChange: boolean = true): Promise<void> {
    this.ensureUnlocked();
    const sessionKey = this.sessionKeyToken;
    if (sessionKey === null) {
      throw new Error('Session key is missing');
    }
    if (markLocalChange) {
      this.recordLocalMutationForSync();
      this.snapshot.syncSettings.hasLocalChanges = true;
    }
    this.snapshot = sanitizeRuntimePayload(this.snapshot);
    this.snapshot.updatedAt = Date.now();

    const encryptedVault = await this.crypto.encryptString(
      JSON.stringify(this.snapshot),
      sessionKey,
    );
    const envelope: VaultPersistenceEnvelope = {
      schemaVersion: VaultController.SCHEMA_VERSION,
      masterKeyRecord: this.masterKeyRecord,
      encryptedVault,
      unlockGuard: cloneUnlockGuardState(this.unlockGuard),
      updatedAt: this.snapshot.updatedAt,
    };
    await this.store.writeEnvelope(envelope);
  }

  private recordLocalMutationForSync(): void {
    this.localChangeRevision += 1;
    if (this.syncInProgress) {
      this.syncRequestedAgain = true;
    }
  }

  private localRevisionChangedSince(revision: number): boolean {
    return this.localChangeRevision !== revision;
  }

  private async persistUnlockGuardOnly(): Promise<void> {
    const envelope = await this.readEnvelope();
    envelope.unlockGuard = cloneUnlockGuardState(this.unlockGuard);
    envelope.updatedAt = Date.now();
    await this.store.writeEnvelope(envelope);
  }

  private async resetUnlockGuard(): Promise<void> {
    if (this.unlockGuard.failedAttempts === 0 && this.unlockGuard.lockUntil === 0) {
      return;
    }
    this.unlockGuard = defaultUnlockGuardState();
    await this.persistUnlockGuardOnly();
  }

  private async onUnlockFailure(reason: string): Promise<void> {
    const now = Date.now();
    const failedAttempts = this.unlockGuard.failedAttempts + 1;
    const remaining = MAX_UNLOCK_ATTEMPTS - failedAttempts;

    if (failedAttempts >= MAX_UNLOCK_ATTEMPTS) {
      this.unlockGuard = {
        failedAttempts: 0,
        lockUntil: now + LOCKOUT_DURATION_MS,
      };
      const lockMinutes = Math.floor(LOCKOUT_DURATION_MS / 1000 / 60);
      this.lastUnlockError = `失败次数过多，已锁定 ${lockMinutes} 分钟`;
    } else {
      this.unlockGuard = {
        failedAttempts,
        lockUntil: 0,
      };
      this.lastUnlockError = `${reason}，剩余 ${remaining} 次尝试`;
    }
    await this.persistUnlockGuardOnly();
  }

  private async readEnvelope(): Promise<VaultPersistenceEnvelope> {
    const envelope = await this.store.readEnvelope();
    if (envelope === null) {
      return {
        schemaVersion: VaultController.SCHEMA_VERSION,
        masterKeyRecord: null,
        encryptedVault: null,
        unlockGuard: defaultUnlockGuardState(),
        updatedAt: Date.now(),
      };
    }
    return {
      schemaVersion: envelope.schemaVersion || VaultController.SCHEMA_VERSION,
      masterKeyRecord: envelope.masterKeyRecord ?? null,
      encryptedVault: envelope.encryptedVault ?? null,
      unlockGuard: normalizeUnlockGuardState(envelope.unlockGuard),
      updatedAt: envelope.updatedAt || Date.now(),
    };
  }

  private buildSyncClient(settings: SyncSettings): RemoteSyncClient | null {
    switch (settings.providerType) {
      case SyncProviderType.NONE:
        return null;
      case SyncProviderType.WEBDAV:
      case SyncProviderType.NAS_WEBDAV:
        if (
          settings.webdavUrl.trim().length === 0 ||
          settings.webdavPath.trim().length === 0
        ) {
          return null;
        }
        return new WebDavSyncClient(
          settings.webdavUrl,
          settings.webdavPath,
          settings.webdavUsername,
          settings.webdavPassword,
        );
      case SyncProviderType.S3_PRESIGNED:
        if (settings.presignedUploadUrl.trim().length === 0) {
          return null;
        }
        return new PresignedUrlSyncClient(
          settings.presignedDownloadUrl,
          settings.presignedUploadUrl,
        );
      case SyncProviderType.TENCENT_COS:
      case SyncProviderType.ALIYUN_OSS:
        if (
          settings.objectStorageAccessKeyId.trim().length === 0 ||
          settings.objectStorageSecretAccessKey.trim().length === 0 ||
          settings.objectStorageBucket.trim().length === 0
        ) {
          return null;
        }
        return new ObjectStorageSyncClient(
          this.syncContext,
          settings.providerType,
          settings.objectStorageAccessKeyId,
          settings.objectStorageSecretAccessKey,
          settings.objectStorageBucket,
          settings.objectStorageEndpoint,
          settings.objectStorageAppId,
          settings.objectStorageCustomUrl,
          settings.objectStorageObjectKey,
        );
      default:
        return null;
    }
  }

  private async buildSyncPayload(
    payload: VaultRuntimePayload,
    revision: number,
    settings: SyncSettings,
    masterKey: MasterKeyRecord | null,
  ): Promise<string> {
    const sessionKey = this.sessionKeyToken;
    if (sessionKey === null) {
      throw new Error('Session key is missing');
    }
    const normalizedPayload = sanitizeRuntimePayload(payload);
    const encryptedVault = await this.crypto.encryptString(
      JSON.stringify(normalizedPayload),
      sessionKey,
    );
    const syncEnvelope: SyncEnvelope = {
      version: VaultController.SCHEMA_VERSION,
      exportedAt: new Date().toISOString(),
      deviceId: settings.deviceId,
      revision,
      masterKeyRecord: settings.syncMasterKey ? masterKey : null,
      encryptedVault,
    };
    return JSON.stringify(syncEnvelope);
  }

  private mergePayloads(
    local: VaultRuntimePayload,
    remote: VaultRuntimePayload,
    strategy: ConflictStrategy,
  ): VaultRuntimePayload {
    const localMap = new Map<string, VaultEntry>();
    local.entries.forEach((entry: VaultEntry) => putCanonicalEntry(localMap, entry));

    const remoteMap = new Map<string, VaultEntry>();
    remote.entries.forEach((entry: VaultEntry) => putCanonicalEntry(remoteMap, entry));

    const allIds = new Set<string>();
    localMap.forEach((_value, key) => allIds.add(key));
    remoteMap.forEach((_value, key) => allIds.add(key));

    const mergedEntries: VaultEntry[] = [];
    allIds.forEach((id: string) => {
      const localEntry = localMap.get(id);
      const remoteEntry = remoteMap.get(id);

      if (localEntry === undefined && remoteEntry !== undefined) {
        mergedEntries.push(remoteEntry);
        return;
      }
      if (remoteEntry === undefined && localEntry !== undefined) {
        mergedEntries.push(localEntry);
        return;
      }
      if (localEntry === undefined || remoteEntry === undefined) {
        return;
      }

      if (isSameEntry(localEntry, remoteEntry)) {
        mergedEntries.push(
          localEntry.updatedAt >= remoteEntry.updatedAt ? localEntry : remoteEntry,
        );
        return;
      }

      if (strategy === ConflictStrategy.REMOTE_WINS) {
        mergedEntries.push(remoteEntry);
        return;
      }

      if (strategy === ConflictStrategy.LOCAL_WINS) {
        mergedEntries.push(localEntry);
        return;
      }

      const keepLocal = localEntry.updatedAt >= remoteEntry.updatedAt;
      const winner = keepLocal ? localEntry : remoteEntry;
      const loser = keepLocal ? remoteEntry : localEntry;
      mergedEntries.push(winner);
      if (!loser.isDeleted) {
        const duplicate = deepCopyEntry(loser);
        duplicate.id = nextId();
        duplicate.createdAt = Date.now();
        duplicate.updatedAt = duplicate.createdAt;
        const source = keepLocal ? '远端' : '本地';
        duplicate.label =
          loser.label.trim().length === 0
            ? `冲突副本-${source}`
            : `${loser.label} (冲突-${source})`;
        mergedEntries.push(duplicate);
      }
    });

    const categoryStates = mergeCategoryStatesForSync(local, remote, strategy);
    const deletedCategoryKeys = new Set<string>();
    categoryStates.forEach((state: CategorySyncState) => {
      if (state.isDeleted) {
        deletedCategoryKeys.add(state.name.trim().toLowerCase());
      }
    });
    mergedEntries.forEach((entry: VaultEntry) => {
      const category = this.entryCategory(entry);
      if (!entry.isDeleted && deletedCategoryKeys.has(category.toLowerCase())) {
        this.setEntryCategory(entry, '');
        entry.updatedAt = Date.now();
      }
    });
    const tags = new Set<string>();
    const categories = new Set<string>();
    const localHasChanges = local.syncSettings.hasLocalChanges;
    const shouldMergeCleanLocalTaxonomy =
      strategy === ConflictStrategy.KEEP_BOTH && !localHasChanges;
    const baseTags = shouldMergeCleanLocalTaxonomy
      ? local.tags.concat(remote.tags)
      : (localHasChanges ? local.tags : remote.tags);
    const baseTemplates = shouldMergeCleanLocalTaxonomy
      ? remote.categoryTemplates.concat(local.categoryTemplates)
      : (localHasChanges ? local.categoryTemplates : remote.categoryTemplates);
    baseTags.forEach((tag: string) => tags.add(tag));
    categoryStates.filter((state: CategorySyncState) => !state.isDeleted)
      .forEach((state: CategorySyncState) => categories.add(state.name));
    baseTemplates.forEach((template: CategoryTemplate) => {
      if (!deletedCategoryKeys.has(template.category.trim().toLowerCase())) {
        categories.add(template.category);
      }
    });
    mergedEntries.filter((entry: VaultEntry) => !entry.isDeleted).forEach((entry: VaultEntry) => {
      entry.tags.forEach((tag: string) => tags.add(tag));
      const category = this.entryCategory(entry);
      if (category.length > 0) {
        if (!deletedCategoryKeys.has(category.toLowerCase())) {
          categories.add(category);
        }
      }
    });

    return {
      tags: normalizeTags(setToArray(tags)),
      categories: normalizeTags(setToArray(categories)),
      categoryTemplates: mergeCategoryTemplates(
        baseTemplates,
        local.categoryTemplates,
        remote.categoryTemplates,
        setToArray(categories),
      ),
      categoryStates,
      entries: mergedEntries,
      security: pickMergedSecurity(local, remote, strategy),
      updatedAt: Math.max(local.updatedAt, remote.updatedAt, Date.now()),
      syncSettings: cloneSyncSettings(local.syncSettings),
    };
  }

  private recordSyncStatus(
    status: string,
    message: string,
    revision: number,
    remoteFingerprint?: string,
  ): void {
    const settings = cloneSyncSettings(this.snapshot.syncSettings);
    const safeMessage = sanitizeLogMessage(message);
    const now = Date.now();
    settings.lastSyncAt = now;
    settings.lastSyncStatus = status;
    settings.lastSyncMessage = safeMessage;
    settings.lastSyncRevision = revision;
    if (remoteFingerprint !== undefined) {
      settings.lastRemoteFingerprint = remoteFingerprint;
    }

    const newLog: SyncLogEntry = {
      timestamp: now,
      level: status === 'error' ? 'error' : 'info',
      message: safeMessage,
    };
    const normalizedLogs = settings.logs.filter(
      (entry: SyncLogEntry) => !isSyncTimingLogMessage(entry.message),
    );
    const logs = [newLog, ...normalizedLogs];
    settings.logs = logs.length > 50 ? logs.slice(0, 50) : logs;

    this.snapshot.syncSettings = settings;
  }
}

function createEmptyPayload(): VaultRuntimePayload {
  return {
    tags: [],
    categories: [],
    categoryTemplates: [],
    categoryStates: [],
    entries: [],
    security: defaultSecuritySettings(),
    updatedAt: Date.now(),
    syncSettings: defaultSyncSettings(),
  };
}

function createScopedItemExportRecord(
  item: object,
  categoryTemplates: CategoryTemplate[],
  exportedAt: string,
): ExportSingleItemRecord {
  return {
    version: 2,
    scope: 'item',
    exportedAt,
    item,
    categoryTemplates: categoryTemplates.map((template: CategoryTemplate) =>
      cloneCategoryTemplate(template)
    ),
  };
}

function createScopedCategoryExportRecord(
  category: string,
  items: ExportItemRecord[],
  categoryTemplates: CategoryTemplate[],
  exportedAt: string,
): ExportCategoryRecord {
  return {
    version: 2,
    scope: 'category',
    exportedAt,
    category,
    count: items.length,
    items,
    categoryTemplates: categoryTemplates.map((template: CategoryTemplate) =>
      cloneCategoryTemplate(template)
    ),
  };
}

function decodeScopedImportRecord(contents: string, scope: string): DecodedScopedImportRecord {
  const parsed = JSON.parse(contents) as ImportSingleItemRecord | ImportCategoryRecord;
  const version = typeof parsed.version === 'number' ? parsed.version : 1;
  const categoryTemplates = normalizeCategoryTemplates(parsed.categoryTemplates, []);
  if (scope === 'item') {
    const single = parsed as ImportSingleItemRecord;
    if (single.scope !== 'item' || single.item === undefined) {
      throw new Error('不是单条条目导出 JSON');
    }
    return {
      version,
      items: [single.item],
      categoryTemplates,
    };
  }
  const category = parsed as ImportCategoryRecord;
  if (category.scope !== 'category' || category.items === undefined) {
    throw new Error('不是分类导出 JSON');
  }
  return {
    version,
    items: category.items,
    categoryTemplates,
  };
}

function sanitizeRuntimePayload(
  input: VaultPayloadRecord | VaultRuntimePayload,
): VaultRuntimePayload {
  const runtimePayload = input as VaultRuntimePayload;
  const maybeSettings = hasSyncSettings(input) ? runtimePayload.syncSettings : undefined;
  const maybeSecurity = input.security;
  const normalizedEntryMap = new Map<string, VaultEntry>();
  (input.entries ?? []).forEach((entry: VaultEntry) => putCanonicalEntry(normalizedEntryMap, entry));
  const normalizedEntries: VaultEntry[] = [];
  normalizedEntryMap.forEach((entry: VaultEntry) => normalizedEntries.push(entry));
  const updatedAt = typeof input.updatedAt === 'number' ? input.updatedAt : Date.now();
  const categoryStates = normalizeCategoryStates(
    input.categoryStates,
    input.categories ?? [],
    input.categoryTemplates ?? [],
    normalizedEntries,
    updatedAt,
  );
  const deletedCategoryKeys = new Set<string>();
  categoryStates.forEach((state: CategorySyncState) => {
    if (state.isDeleted) {
      deletedCategoryKeys.add(state.name.trim().toLowerCase());
    }
  });
  normalizedEntries.forEach((entry: VaultEntry) => {
    const category = resolveEntryCategory(entry);
    if (!entry.isDeleted && deletedCategoryKeys.has(category.toLowerCase())) {
      const payload = entry.payload as CategoryCarrier;
      payload.category = '';
    }
  });
  const tagUnion = new Set<string>();
  const categoryUnion = new Set<string>();
  normalizeTags(input.tags ?? []).forEach((tag: string) => tagUnion.add(tag));
  normalizeTags(input.categories ?? []).forEach((category: string) => {
    if (!deletedCategoryKeys.has(category.toLowerCase())) {
      categoryUnion.add(category);
    }
  });
  normalizedEntries.filter((entry: VaultEntry) => !entry.isDeleted).forEach((entry: VaultEntry) => {
    entry.tags.forEach((tag: string) => tagUnion.add(tag));
    const category = resolveEntryCategory(entry);
    if (category.length > 0) {
      if (!deletedCategoryKeys.has(category.toLowerCase())) {
        categoryUnion.add(category);
      }
    }
  });
  categoryStates.filter((state: CategorySyncState) => !state.isDeleted)
    .forEach((state: CategorySyncState) => categoryUnion.add(state.name));
  const templates = normalizeCategoryTemplates(
    input.categoryTemplates,
    setToArray(categoryUnion),
  ).filter((template: CategoryTemplate) =>
    !deletedCategoryKeys.has(template.category.trim().toLowerCase())
  );
  return {
    tags: normalizeTags(setToArray(tagUnion)),
    categories: normalizeTags(setToArray(categoryUnion)),
    categoryTemplates: templates,
    categoryStates,
    entries: normalizedEntries,
    security: normalizeSecuritySettings(maybeSecurity),
    updatedAt,
    syncSettings: normalizeSyncSettings(
      maybeSettings === undefined ? defaultSyncSettings() : maybeSettings,
    ),
  };
}

function normalizeRuntimeEntry(entry: VaultEntry): VaultEntry {
  const normalized = deepCopyEntry(entry);
  const carrier = normalized as EntryCarrier;
  const payload: EntryPayloadCarrier =
    carrier.payload ?? createEmptyEntryPayloadCarrier();
  carrier.id = canonicalIdString(carrier.id ?? '');
  if (carrier.id.length === 0) {
    carrier.id = nextId();
  }
  const mergedTags = normalizeTags([
    ...readStringArray(carrier.tags),
    ...readStringArray(carrier.metadataTags),
    ...readStringArray(payload.tags),
    ...readStringArray(payload.metadataTags),
  ]);
  const resolvedCategory = pickFirstNonEmpty([
    readString(payload.category),
    readString(payload.metadataCategory),
    readString(carrier.category),
    readString(carrier.metadataCategory),
  ]);
  carrier.tags = mergedTags;
  payload.tags = mergedTags;
  payload.category = resolvedCategory;
  carrier.customFields = normalizeCustomFields(carrier.customFields);
  carrier.payload = payload;
  normalizeEntryAccounts(carrier);
  normalizeServiceReferences(carrier);
  carrier.label = readString(carrier.label);
  if (typeof carrier.isDeleted !== 'boolean') {
    carrier.isDeleted = false;
  }
  if (!isValidTimestamp(carrier.createdAt)) {
    carrier.createdAt = Date.now();
  }
  if (!isValidTimestamp(carrier.updatedAt)) {
    carrier.updatedAt = carrier.createdAt;
  }
  if ((carrier.updatedAt ?? 0) < (carrier.createdAt ?? 0)) {
    carrier.updatedAt = carrier.createdAt;
  }
  return normalizeLegacyCredentialEntry(normalized);
}

function resolveEntryCategory(entry: VaultEntry): string {
  const carrier = entry as EntryCarrier;
  const payload: EntryPayloadCarrier =
    carrier.payload ?? createEmptyEntryPayloadCarrier();
  return pickFirstNonEmpty([
    readString(payload.category),
    readString(payload.metadataCategory),
    readString(carrier.category),
    readString(carrier.metadataCategory),
  ]);
}

function createEmptyEntryPayloadCarrier(): EntryPayloadCarrier {
  return {
    category: '',
    metadataCategory: '',
    tags: [],
    metadataTags: [],
  };
}

function readString(value: string | undefined): string {
  return typeof value === 'string' ? value.trim() : '';
}

function canonicalIdString(value: string | undefined): string {
  const clean = readString(value);
  if (clean.length === 0) {
    return '';
  }
  const uuidPattern =
    /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
  return uuidPattern.test(clean) ? clean.toLowerCase() : clean;
}

function normalizeReferenceIds(values: string[] | undefined): string[] {
  if (values === undefined) {
    return [];
  }
  const normalized: string[] = [];
  values.forEach((value: string) => {
    const id = canonicalIdString(value);
    if (id.length > 0) {
      normalized.push(id);
    }
  });
  return normalized;
}

function mappedReferenceId(idMap: Map<string, string>, value: string | undefined): string {
  const id = canonicalIdString(value);
  if (id.length === 0) {
    return '';
  }
  return idMap.get(id) ?? id;
}

function normalizeServiceReferences(carrier: EntryCarrier): void {
  if (carrier.type !== VaultEntryType.SERVICE) {
    return;
  }
  const payload = carrier.payload as ServiceReferenceCarrier;
  payload.accountId = canonicalIdString(payload.accountId);
  payload.serverIds = normalizeReferenceIds(payload.serverIds);
}

function normalizeEntryAccounts(carrier: EntryCarrier): void {
  if (
    carrier.type !== VaultEntryType.CREDENTIAL &&
    carrier.type !== VaultEntryType.SERVER &&
    carrier.type !== VaultEntryType.SERVICE
  ) {
    return;
  }
  const payload = carrier.payload as AccountCarrier;
  payload.accounts = normalizeServiceAccounts(payload.accounts);
}

function normalizeExportItem(item: ExportItemRecord): ExportItemRecord {
  const normalized = JSON.parse(JSON.stringify(item)) as ExportItemRecord;
  normalized.id = canonicalIdString(normalized.id);
  normalized.customFields = normalizeCustomFields(normalized.customFields);
  if (normalized.type === VaultEntryType.SERVICE) {
    const payload = normalized.payload as ServiceReferenceCarrier;
    payload.accountId = canonicalIdString(payload.accountId);
    payload.serverIds = normalizeReferenceIds(payload.serverIds);
  }
  return normalized;
}

function pickFirstNonEmpty(values: string[]): string {
  for (let index = 0; index < values.length; index++) {
    const current = values[index];
    if (current.length > 0) {
      return current;
    }
  }
  return '';
}

function readStringArray(value: string[] | undefined): string[] {
  if (value === undefined) {
    return [];
  }
  const normalized: string[] = [];
  value.forEach((entry: string) => {
    const clean = entry.trim();
    if (clean.length > 0) {
      normalized.push(clean);
    }
  });
  return normalized;
}

function isValidTimestamp(value: number | undefined): boolean {
  return typeof value === 'number' && Number.isFinite(value) && value > 0;
}

function normalizeSyncSettings(settings: SyncSettings): SyncSettings {
  const normalized = cloneSyncSettings(settings);
  if (normalized.webdavPath.trim().length === 0) {
    normalized.webdavPath = '/vault.json';
  }
  if (normalized.objectStorageObjectKey.trim().length === 0) {
    normalized.objectStorageObjectKey = 'vault.sync.json';
  }
  normalized.autoSyncIntervalUnit = normalized.autoSyncIntervalUnit ?? SyncIntervalUnit.MINUTES;
  normalized.autoSyncIntervalValue = normalizeIntervalValue(
    normalized.autoSyncIntervalValue,
    normalized.autoSyncIntervalMinutes,
  );
  normalized.autoSyncIntervalMinutes = normalizeIntervalMinutes(
    normalized.autoSyncIntervalMinutes,
    normalized.autoSyncIntervalValue,
    normalized.autoSyncIntervalUnit,
  );
  normalized.logs = normalized.logs
    .slice(0, 50)
    .map((log: SyncLogEntry) => {
      const normalizedLog: SyncLogEntry = {
        timestamp: typeof log.timestamp === 'number' ? log.timestamp : Date.now(),
        level: log.level === 'error' ? 'error' : 'info',
        message: log.message ?? '',
      };
      return normalizedLog;
    })
    .filter((log: SyncLogEntry) => !isSyncTimingLogMessage(log.message));
  normalized.hasLocalChanges = normalized.hasLocalChanges === true;
  normalized.lastRemoteFingerprint = normalized.lastRemoteFingerprint ?? '';
  return normalized;
}

function autoSyncIntervalMillis(settings: SyncSettings): number {
  const value = Math.max(Math.floor(settings.autoSyncIntervalValue || 0), 1);
  if (settings.autoSyncIntervalUnit === SyncIntervalUnit.SECONDS) {
    return value * 1000;
  }
  return value * 60 * 1000;
}

function isSuccessfulRemoteStatus(statusCode: number): boolean {
  return (statusCode >= 200 && statusCode < 300) || statusCode === 404;
}

function isSyncTimingLogMessage(message: string): boolean {
  return message.includes('同步耗时(');
}

function cloneSyncSettings(settings: SyncSettings): SyncSettings {
  return {
    providerType: settings.providerType,
    webdavUrl: settings.webdavUrl,
    webdavUsername: settings.webdavUsername,
    webdavPassword: settings.webdavPassword,
    webdavPath: settings.webdavPath,
    presignedDownloadUrl: settings.presignedDownloadUrl,
    presignedUploadUrl: settings.presignedUploadUrl,
    objectStorageAccessKeyId: settings.objectStorageAccessKeyId ?? '',
    objectStorageSecretAccessKey: settings.objectStorageSecretAccessKey ?? '',
    objectStorageBucket: settings.objectStorageBucket ?? '',
    objectStorageEndpoint: settings.objectStorageEndpoint ?? '',
    objectStorageAppId: settings.objectStorageAppId ?? '',
    objectStorageCustomUrl: settings.objectStorageCustomUrl ?? '',
    objectStorageObjectKey: settings.objectStorageObjectKey ?? 'vault.sync.json',
    autoSyncEnabled: settings.autoSyncEnabled,
    autoSyncIntervalMinutes: settings.autoSyncIntervalMinutes,
    autoSyncIntervalValue: settings.autoSyncIntervalValue,
    autoSyncIntervalUnit: settings.autoSyncIntervalUnit,
    autoSyncOnUnlock: settings.autoSyncOnUnlock,
    conflictStrategy: settings.conflictStrategy,
    syncMasterKey: settings.syncMasterKey,
    deviceId: settings.deviceId,
    lastSyncRevision: settings.lastSyncRevision,
    lastSyncAt: settings.lastSyncAt,
    lastSyncStatus: settings.lastSyncStatus,
    lastSyncMessage: settings.lastSyncMessage,
    lastRemoteFingerprint: settings.lastRemoteFingerprint ?? '',
    hasLocalChanges: settings.hasLocalChanges === true,
    logs: settings.logs.map((entry: SyncLogEntry) => {
      const log: SyncLogEntry = {
        timestamp: entry.timestamp,
        level: entry.level,
        message: entry.message,
      };
      return log;
    }),
  };
}

function normalizeIntervalValue(value: number | undefined, fallback: number): number {
  const candidate = typeof value === 'number' && Number.isFinite(value) ? value : fallback;
  return Math.min(Math.max(Math.floor(candidate), 1), 1440);
}

function normalizeIntervalMinutes(
  minutes: number | undefined,
  value: number,
  unit: SyncIntervalUnit | undefined,
): number {
  const candidate = typeof minutes === 'number' && Number.isFinite(minutes)
    ? minutes
    : intervalValueToMinutes(value, unit ?? SyncIntervalUnit.MINUTES);
  return Math.min(Math.max(Math.floor(candidate), 1), 1440);
}

function intervalValueToMinutes(value: number, unit: SyncIntervalUnit): number {
  const safeValue = Math.min(Math.max(Math.floor(value), 1), 1440);
  if (unit === SyncIntervalUnit.SECONDS) {
    return Math.max(Math.ceil(safeValue / 60), 1);
  }
  return Math.max(safeValue, 1);
}

function defaultSecuritySettings(): SecuritySettings {
  return {
    requireTotp: false,
    totpSecret: '',
    biometricUnlockEnabled: false,
    idleAutoLockMinutes: 0,
  };
}

function normalizeSecuritySettings(
  input: SecuritySettings | undefined,
): SecuritySettings {
  if (input === undefined) {
    return defaultSecuritySettings();
  }
  const secret = typeof input.totpSecret === 'string' ? input.totpSecret.trim() : '';
  const requireTotp = input.requireTotp === true && secret.length > 0;
  return {
    requireTotp,
    totpSecret: secret,
    biometricUnlockEnabled: input.biometricUnlockEnabled === true,
    idleAutoLockMinutes: normalizeIdleAutoLockMinutes(input.idleAutoLockMinutes),
  };
}

function defaultCategoryFields(): FieldTemplate[] {
  return [
    createFieldTemplate('名称'),
    createFieldTemplate('备注'),
  ];
}

function fieldsForPreset(preset: CategoryTypePreset): FieldTemplate[] {
  return fieldsForCategoryPreset(preset);
}

function fieldsForCategoryPreset(
  preset: CategoryTypePreset | '',
  customFieldNames: string[] = [],
): FieldTemplate[] {
  let names: string[] = [];
  if (preset === CategoryTypePreset.SERVER) {
    names = ['IP地址', '端口', '关联账号'];
  } else if (preset === CategoryTypePreset.SERVICE) {
    names = ['服务入口', '关联账号', '关联服务器'];
  } else if (preset === CategoryTypePreset.ACCOUNT) {
    names = ['入口'];
  }
  const fields = defaultCategoryFields();
  names.forEach((name: string) => fields.push(createFieldTemplate(name)));
  customFieldNames.forEach((name: string) => fields.push(createFieldTemplate(name)));
  return normalizeFieldTemplates(fields);
}

function createFieldTemplate(name: string): FieldTemplate {
  return {
    id: stableFieldId(name),
    name,
    valueType: 'text',
    targetCategory: '',
    targetFieldId: '',
  };
}

function stableFieldId(name: string): string {
  const trimmed = name.trim();
  const clean = trimmed.toLowerCase();
  let output = '';
  for (let index = 0; index < clean.length; index++) {
    const char = clean.charAt(index);
    const keep =
      (char >= 'a' && char <= 'z') ||
      (char >= '0' && char <= '9') ||
      (char >= '\u4e00' && char <= '\u9fff');
    output += keep ? char : '_';
  }
  output = output.replace(/_+/g, '_');
  while (output.startsWith('_')) {
    output = output.substring(1);
  }
  while (output.endsWith('_')) {
    output = output.substring(0, output.length - 1);
  }
  if (output.length > 0) {
    return `template_${output}`;
  }
  if (trimmed.length === 0) {
    return 'template_empty';
  }
  return `template_u_${utf8Hex(trimmed)}`;
}

function utf8Hex(value: string): string {
  const encoded = unescape(encodeURIComponent(value));
  let output = '';
  for (let index = 0; index < encoded.length; index++) {
    output += encoded.charCodeAt(index).toString(16).padStart(2, '0');
  }
  return output;
}

function cloneCategoryVersion(version: Record<string, number> | undefined): Record<string, number> {
  const output: Record<string, number> = {};
  if (version === undefined) {
    return output;
  }
  Object.keys(version).forEach((key: string) => {
    const value = version[key];
    if (typeof value === 'number' && Number.isFinite(value) && value > 0) {
      output[key] = Math.floor(value);
    }
  });
  return output;
}

function mergedCategoryVersion(
  local: Record<string, number>,
  remote: Record<string, number>,
): Record<string, number> {
  const output = cloneCategoryVersion(local);
  Object.keys(remote).forEach((key: string) => {
    output[key] = Math.max(output[key] ?? 0, remote[key] ?? 0);
  });
  return output;
}

function compareCategoryVersion(
  local: Record<string, number>,
  remote: Record<string, number>,
): string {
  let localGreater = false;
  let remoteGreater = false;
  const keys = new Set<string>();
  Object.keys(local).forEach((key: string) => keys.add(key));
  Object.keys(remote).forEach((key: string) => keys.add(key));
  keys.forEach((key: string) => {
    const localValue = local[key] ?? 0;
    const remoteValue = remote[key] ?? 0;
    if (localValue > remoteValue) {
      localGreater = true;
    } else if (remoteValue > localValue) {
      remoteGreater = true;
    }
  });
  if (localGreater && remoteGreater) {
    return 'concurrent';
  }
  if (localGreater) {
    return 'local';
  }
  if (remoteGreater) {
    return 'remote';
  }
  return 'equal';
}

function normalizeCategorySyncState(
  state: CategorySyncState,
  fallbackUpdatedAt: number,
): CategorySyncState {
  const name = readString(state.name);
  const updater = readString(state.updatedBy).length > 0 ? readString(state.updatedBy) : 'legacy';
  const version = cloneCategoryVersion(state.version);
  if (Object.keys(version).length === 0) {
    version[updater] = 1;
  }
  return {
    name,
    isDeleted: state.isDeleted === true,
    updatedAt: typeof state.updatedAt === 'number' ? state.updatedAt : fallbackUpdatedAt,
    version,
    updatedBy: updater,
  };
}

function resolveCategorySyncState(
  local: CategorySyncState,
  remote: CategorySyncState,
  strategy: ConflictStrategy,
): CategorySyncState {
  const comparison = compareCategoryVersion(local.version, remote.version);
  if (comparison === 'local') {
    return local;
  }
  if (comparison === 'remote') {
    return remote;
  }
  let selected: CategorySyncState;
  if (local.isDeleted !== remote.isDeleted) {
    selected = local.isDeleted ? local : remote;
  } else if (strategy === ConflictStrategy.LOCAL_WINS) {
    selected = local;
  } else if (strategy === ConflictStrategy.REMOTE_WINS) {
    selected = remote;
  } else {
    selected = local.updatedAt >= remote.updatedAt ? local : remote;
  }
  return {
    name: selected.name,
    isDeleted: selected.isDeleted,
    updatedAt: Math.max(local.updatedAt, remote.updatedAt),
    version: mergedCategoryVersion(local.version, remote.version),
    updatedBy: selected.updatedBy,
  };
}

function normalizeCategoryStates(
  states: CategorySyncState[] | undefined,
  categories: string[],
  templates: CategoryTemplate[],
  entries: VaultEntry[],
  updatedAt: number,
): CategorySyncState[] {
  const output = new Map<string, CategorySyncState>();
  (states ?? []).forEach((rawState: CategorySyncState) => {
    const state = normalizeCategorySyncState(rawState, updatedAt);
    const key = state.name.toLowerCase();
    if (key.length === 0) {
      return;
    }
    const existing = output.get(key);
    output.set(
      key,
      existing === undefined
        ? state
        : resolveCategorySyncState(existing, state, ConflictStrategy.KEEP_BOTH),
    );
  });
  const legacyNames = categories
    .concat(templates.map((template: CategoryTemplate) => template.category))
    .concat(entries.filter((entry: VaultEntry) => !entry.isDeleted)
      .map((entry: VaultEntry) => resolveEntryCategory(entry)));
  legacyNames.forEach((rawName: string) => {
    const name = rawName.trim();
    const key = name.toLowerCase();
    if (name.length === 0 || output.has(key)) {
      return;
    }
    output.set(key, {
      name,
      isDeleted: false,
      updatedAt,
      version: { 'legacy': 1 },
      updatedBy: 'legacy',
    });
  });
  const normalized: CategorySyncState[] = [];
  output.forEach((state: CategorySyncState) => normalized.push(state));
  normalized.sort((a: CategorySyncState, b: CategorySyncState) =>
    a.name.localeCompare(b.name)
  );
  return normalized;
}

function categoryTombstone(
  state: CategorySyncState,
  deviceId: string,
  updatedAt: number,
): CategorySyncState {
  const updater = deviceId.trim().length > 0 ? deviceId : 'legacy';
  const version = cloneCategoryVersion(state.version);
  version[updater] = (version[updater] ?? 0) + 1;
  return {
    name: state.name,
    isDeleted: true,
    updatedAt,
    version,
    updatedBy: updater,
  };
}

function mergeCategoryStatesForSync(
  local: VaultRuntimePayload,
  remote: VaultRuntimePayload,
  strategy: ConflictStrategy,
): CategorySyncState[] {
  const localStates = new Map<string, CategorySyncState>();
  normalizeCategoryStates(
    local.categoryStates,
    local.categories,
    local.categoryTemplates,
    local.entries,
    local.updatedAt,
  ).forEach((state: CategorySyncState) => localStates.set(state.name.toLowerCase(), state));
  const remoteStates = new Map<string, CategorySyncState>();
  normalizeCategoryStates(
    remote.categoryStates,
    remote.categories,
    remote.categoryTemplates,
    remote.entries,
    remote.updatedAt,
  ).forEach((state: CategorySyncState) => remoteStates.set(state.name.toLowerCase(), state));

  if (local.syncSettings.hasLocalChanges) {
    remoteStates.forEach((state: CategorySyncState, key: string) => {
      if (!state.isDeleted && !localStates.has(key)) {
        localStates.set(
          key,
          categoryTombstone(state, local.syncSettings.deviceId, local.updatedAt),
        );
      }
    });
  } else if (strategy === ConflictStrategy.REMOTE_WINS) {
    localStates.forEach((state: CategorySyncState, key: string) => {
      if (!state.isDeleted && !remoteStates.has(key)) {
        remoteStates.set(key, categoryTombstone(state, 'legacy-remote', remote.updatedAt));
      }
    });
  }

  const keys = new Set<string>();
  localStates.forEach((_state: CategorySyncState, key: string) => keys.add(key));
  remoteStates.forEach((_state: CategorySyncState, key: string) => keys.add(key));
  const merged: CategorySyncState[] = [];
  keys.forEach((key: string) => {
    const localState = localStates.get(key);
    const remoteState = remoteStates.get(key);
    if (localState !== undefined && remoteState !== undefined) {
      merged.push(resolveCategorySyncState(localState, remoteState, strategy));
    } else if (localState !== undefined) {
      merged.push(localState);
    } else if (remoteState !== undefined) {
      merged.push(remoteState);
    }
  });
  merged.sort((a: CategorySyncState, b: CategorySyncState) => a.name.localeCompare(b.name));
  return merged;
}

function normalizeCategoryTemplates(
  templates: CategoryTemplate[] | undefined,
  categories: string[],
): CategoryTemplate[] {
  const map = new Map<string, CategoryTemplate>();
  (templates ?? []).forEach((template: CategoryTemplate) => {
    const normalized = normalizeCategoryTemplate(template);
    if (normalized.category.length > 0) {
      map.set(normalized.category.toLowerCase(), normalized);
    }
  });
  categories.forEach((category: string) => {
    const clean = category.trim();
    if (clean.length === 0) {
      return;
    }
    const key = clean.toLowerCase();
    if (!map.has(key)) {
      map.set(key, normalizeCategoryTemplate({ category: clean, fields: defaultCategoryFields() }));
    }
  });
  const output: CategoryTemplate[] = [];
  map.forEach((template: CategoryTemplate) => output.push(template));
  output.sort((a: CategoryTemplate, b: CategoryTemplate) => a.category.localeCompare(b.category));
  return output;
}

function normalizeCategoryTemplate(template: CategoryTemplate): CategoryTemplate {
  const category = readString(template.category);
  return {
    category,
    fields: normalizeFieldTemplates(template.fields),
  };
}

function normalizeFieldTemplates(fields: FieldTemplate[] | undefined): FieldTemplate[] {
  const source = fields === undefined || fields.length === 0 ? defaultCategoryFields() : fields;
  const seen = new Set<string>();
  const output: FieldTemplate[] = [];
  source.forEach((field: FieldTemplate) => {
    const name = readString(field.name);
    if (name.length === 0) {
      return;
    }
    const key = name.toLowerCase();
    if (seen.has(key)) {
      return;
    }
    seen.add(key);
    const id = canonicalIdString(field.id);
    output.push({
      id: id.length > 0 ? id : stableFieldId(name),
      name,
      valueType: normalizeFieldValueType(field.valueType),
      targetCategory: readPreservedString(field.targetCategory),
      targetFieldId: readPreservedString(field.targetFieldId),
    });
  });
  return output.length > 0 ? output : defaultCategoryFields();
}

function mergeEditableTemplateFields(
  existing: FieldTemplate[],
  requested: FieldTemplate[],
): FieldTemplate[] {
  const existingFields = normalizeFieldTemplates(existing);
  const requestedFields = normalizeFieldTemplates(requested);
  const usedExistingIndexes = new Set<number>();
  const merged: FieldTemplate[] = [];

  requestedFields.forEach((requestedField: FieldTemplate) => {
    const requestedName = readString(requestedField.name).toLowerCase();
    let existingIndex = existingFields.findIndex(
      (field: FieldTemplate, index: number) =>
        !usedExistingIndexes.has(index) && readString(field.name).toLowerCase() === requestedName,
    );
    if (existingIndex < 0) {
      existingIndex = existingFields.findIndex(
        (field: FieldTemplate, index: number) =>
          !usedExistingIndexes.has(index) && normalizeFieldValueType(field.valueType) === 'text',
      );
    }
    if (existingIndex < 0) {
      merged.push(requestedField);
      return;
    }
    usedExistingIndexes.add(existingIndex);
    const existingField = existingFields[existingIndex];
    merged.push({
      id: existingField.id,
      name: requestedField.name,
      valueType: normalizeFieldValueType(existingField.valueType),
      targetCategory: readPreservedString(existingField.targetCategory),
      targetFieldId: readPreservedString(existingField.targetFieldId),
    });
  });

  existingFields.forEach((field: FieldTemplate, index: number) => {
    if (
      !usedExistingIndexes.has(index) &&
      normalizeFieldValueType(field.valueType) !== 'text'
    ) {
      merged.push(cloneFieldTemplate(field));
    }
  });
  return normalizeFieldTemplates(merged);
}

function mergeCategoryTemplates(
  base: CategoryTemplate[],
  local: CategoryTemplate[],
  remote: CategoryTemplate[],
  categories: string[],
): CategoryTemplate[] {
  const merged = new Map<string, CategoryTemplate>();
  base.forEach((template: CategoryTemplate) => {
    const normalized = normalizeCategoryTemplate(template);
    if (normalized.category.length > 0) {
      merged.set(normalized.category.toLowerCase(), normalized);
    }
  });
  local.forEach((template: CategoryTemplate) => {
    const normalized = normalizeCategoryTemplate(template);
    if (normalized.category.length > 0 && !merged.has(normalized.category.toLowerCase())) {
      merged.set(normalized.category.toLowerCase(), normalized);
    }
  });
  remote.forEach((template: CategoryTemplate) => {
    const normalized = normalizeCategoryTemplate(template);
    if (normalized.category.length > 0 && !merged.has(normalized.category.toLowerCase())) {
      merged.set(normalized.category.toLowerCase(), normalized);
    }
  });
  const output: CategoryTemplate[] = [];
  merged.forEach((template: CategoryTemplate) => output.push(template));
  return normalizeCategoryTemplates(output, categories);
}

function mergeImportedCategoryTemplateDefinitions(
  existing: CategoryTemplate[],
  imported: CategoryTemplate[],
): CategoryTemplate[] {
  const merged = existing.map((template: CategoryTemplate) =>
    normalizeCategoryTemplate(template)
  );
  imported.forEach((template: CategoryTemplate) => {
    const incoming = normalizeCategoryTemplate(template);
    if (incoming.category.length === 0) {
      return;
    }
    const templateIndex = merged.findIndex((candidate: CategoryTemplate) =>
      candidate.category.toLowerCase() === incoming.category.toLowerCase()
    );
    if (templateIndex < 0) {
      merged.push(incoming);
      return;
    }
    const fields = merged[templateIndex].fields.map((field: FieldTemplate) =>
      cloneFieldTemplate(field)
    );
    incoming.fields.forEach((field: FieldTemplate) => {
      const fieldIndex = fields.findIndex((candidate: FieldTemplate) => candidate.id === field.id);
      if (fieldIndex < 0) {
        fields.push(cloneFieldTemplate(field));
      } else {
        fields[fieldIndex] = cloneFieldTemplate(field);
      }
    });
    merged[templateIndex] = {
      category: incoming.category,
      fields,
    };
  });
  return normalizeCategoryTemplates(merged, []);
}

function cloneCategoryTemplate(template: CategoryTemplate): CategoryTemplate {
  return {
    category: template.category,
    fields: template.fields.map((field: FieldTemplate) => cloneFieldTemplate(field)),
  };
}

function cloneFieldTemplate(field: FieldTemplate): FieldTemplate {
  return {
    id: field.id,
    name: field.name,
    valueType: normalizeFieldValueType(field.valueType),
    targetCategory: readPreservedString(field.targetCategory),
    targetFieldId: readPreservedString(field.targetFieldId),
  };
}

function categoryTemplatesForExport(
  templates: CategoryTemplate[],
  categories: string[],
): CategoryTemplate[] {
  const selectedCategories = new Set<string>();
  categories.forEach((category: string) => {
    const clean = readString(category);
    if (clean.length > 0) {
      selectedCategories.add(clean.toLowerCase());
    }
  });
  return templates
    .map((template: CategoryTemplate) => normalizeCategoryTemplate(template))
    .filter((template: CategoryTemplate) =>
      selectedCategories.has(template.category.toLowerCase())
    )
    .map((template: CategoryTemplate) => cloneCategoryTemplate(template));
}

function normalizeFieldValueType(value: string | undefined): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    return 'text';
  }
  return value;
}

function readPreservedString(value: string | undefined): string {
  return typeof value === 'string' ? value : '';
}

function cloneSecuritySettings(settings: SecuritySettings): SecuritySettings {
  return {
    requireTotp: settings.requireTotp,
    totpSecret: settings.totpSecret,
    biometricUnlockEnabled: settings.biometricUnlockEnabled === true,
    idleAutoLockMinutes: normalizeIdleAutoLockMinutes(settings.idleAutoLockMinutes),
  };
}

function normalizeIdleAutoLockMinutes(value: number | undefined): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return 0;
  }
  return Math.min(Math.max(Math.floor(value), 0), 1440);
}

function defaultUnlockGuardState(): UnlockGuardState {
  return {
    failedAttempts: 0,
    lockUntil: 0,
  };
}

function normalizeUnlockGuardState(
  input: UnlockGuardState | undefined,
): UnlockGuardState {
  if (input === undefined) {
    return defaultUnlockGuardState();
  }
  return {
    failedAttempts:
      typeof input.failedAttempts === 'number' && input.failedAttempts > 0
        ? Math.floor(input.failedAttempts)
        : 0,
    lockUntil:
      typeof input.lockUntil === 'number' && input.lockUntil > 0
        ? Math.floor(input.lockUntil)
        : 0,
  };
}

function cloneUnlockGuardState(state: UnlockGuardState): UnlockGuardState {
  return {
    failedAttempts: state.failedAttempts,
    lockUntil: state.lockUntil,
  };
}

function pickMergedSecurity(
  local: VaultRuntimePayload,
  remote: VaultRuntimePayload,
  strategy: ConflictStrategy,
): SecuritySettings {
  const localSecurity = normalizeSecuritySettings(local.security);
  const remoteSecurity = normalizeSecuritySettings(remote.security);
  if (strategy === ConflictStrategy.REMOTE_WINS) {
    return remoteSecurity;
  }
  if (strategy === ConflictStrategy.LOCAL_WINS) {
    return localSecurity;
  }
  return local.updatedAt >= remote.updatedAt ? localSecurity : remoteSecurity;
}

function sanitizeLogMessage(message: string): string {
  let safe = message;
  safe = safe.replace(/(password|passwd|pwd)=([^&\s]+)/gi, '$1=***');
  safe = safe.replace(/(token|secret|authorization)=([^&\s]+)/gi, '$1=***');
  safe = safe.replace(/(Bearer\s+)[A-Za-z0-9\-._~+/]+=*/gi, '$1***');
  return safe;
}

function parseSyncEnvelope(payload: string): SyncEnvelope {
  const raw = JSON.parse(payload) as ParsedSyncEnvelopeRecord;
  const encryptedRaw = raw.encryptedVault;
  const masterKeyRaw = raw.masterKeyRecord;
  const encryptedVault =
    encryptedRaw === null || encryptedRaw === undefined
      ? null
      : (encryptedRaw as EncryptedPayloadRecord);
  const masterKeyRecord =
    masterKeyRaw === null || masterKeyRaw === undefined
      ? null
      : (masterKeyRaw as MasterKeyRecord);
  return {
    version: typeof raw.version === 'number' ? raw.version : 1,
    exportedAt: raw.exportedAt ?? '',
    deviceId: raw.deviceId ?? '',
    revision: typeof raw.revision === 'number' ? raw.revision : 0,
    masterKeyRecord,
    encryptedVault,
  };
}

function normalizeLegacyCredentialEntry(entry: VaultEntry): VaultEntry {
  if (entry.type !== VaultEntryType.CREDENTIAL) {
    return entry;
  }
  const payload = entry.payload as AccessKeyCarrier;
  payload.accessKey = resolveAccessKey(payload);
  return entry;
}

function resolveAccessKey(payload: AccessKeyCarrier): string {
  const current = payload.accessKey;
  if (typeof current === 'string') {
    return current;
  }
  const legacy = payload.accessToken;
  return typeof legacy === 'string' ? legacy : '';
}

function normalizeTags(tags: string[]): string[] {
  const uniq = new Set<string>();
  tags
    .map((tag: string) => tag.trim())
    .filter((tag: string) => tag.length > 0)
    .forEach((tag: string) => uniq.add(tag));
  const result = setToArray(uniq);
  result.sort((a: string, b: string) => a.localeCompare(b));
  return result;
}

function normalizeCustomFields(fields: CustomField[] | undefined): CustomField[] {
  if (fields === undefined) {
    return [];
  }
  const result: CustomField[] = [];
  fields.forEach((field: CustomField) => {
    const name = readString(field.name);
    const value = typeof field.value === 'string' ? field.value : '';
    const templateFieldId = canonicalIdString(field.templateFieldId);
    if (name.length === 0 && value.trim().length === 0 && templateFieldId.length === 0) {
      return;
    }
    const id = canonicalIdString(field.id);
    const normalized: CustomField = {
      id: id.length > 0 ? id : nextFieldId(),
      templateFieldId,
      name,
      value,
    };
    result.push(normalized);
  });
  return result;
}

function normalizeServiceAccounts(accounts: ServiceAccount[] | undefined): ServiceAccount[] {
  if (accounts === undefined) {
    return [];
  }
  const result: ServiceAccount[] = [];
  accounts.forEach((account: ServiceAccount) => {
    const username = readString(account.username);
    const password = typeof account.password === 'string' ? account.password : '';
    const note = typeof account.note === 'string' ? account.note : '';
    if (username.length === 0 && password.trim().length === 0 && note.trim().length === 0) {
      return;
    }
    result.push({
      username,
      password,
      note,
    });
  });
  return result;
}

function nextFieldId(): string {
  return util.generateRandomUUID().toLowerCase();
}

function nextId(): string {
  const ts = Date.now().toString(36);
  const rand = Math.floor(Math.random() * 1_000_000_000).toString(36);
  return `${ts}_${rand}`;
}

function backupTimestamp(date: Date = new Date()): string {
  const year = date.getUTCFullYear().toString().padStart(4, '0');
  const month = (date.getUTCMonth() + 1).toString().padStart(2, '0');
  const day = date.getUTCDate().toString().padStart(2, '0');
  const hour = date.getUTCHours().toString().padStart(2, '0');
  const minute = date.getUTCMinutes().toString().padStart(2, '0');
  const second = date.getUTCSeconds().toString().padStart(2, '0');
  return `${year}${month}${day}-${hour}${minute}${second}`;
}

function pathExists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (_error) {
    return false;
  }
}

function putCanonicalEntry(entries: Map<string, VaultEntry>, entry: VaultEntry): void {
  const normalized = normalizeRuntimeEntry(entry);
  const existing = entries.get(normalized.id);
  entries.set(
    normalized.id,
    existing === undefined ? normalized : pickCanonicalDuplicate(existing, normalized),
  );
}

function pickCanonicalDuplicate(existing: VaultEntry, candidate: VaultEntry): VaultEntry {
  if (isSameEntry(existing, candidate)) {
    return existing.updatedAt >= candidate.updatedAt ? existing : candidate;
  }
  if (existing.isDeleted !== candidate.isDeleted) {
    return existing.updatedAt >= candidate.updatedAt ? existing : candidate;
  }
  return existing.updatedAt >= candidate.updatedAt ? existing : candidate;
}

function deepCopyEntry(entry: VaultEntry): VaultEntry {
  return JSON.parse(JSON.stringify(entry)) as VaultEntry;
}

function deepCopyRuntimePayload(payload: VaultRuntimePayload): VaultRuntimePayload {
  return JSON.parse(JSON.stringify(payload)) as VaultRuntimePayload;
}

function isSameEntry(left: VaultEntry, right: VaultEntry): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

function hasSyncSettings(input: VaultPayloadRecord | VaultRuntimePayload): boolean {
  return (input as VaultRuntimePayload).syncSettings !== undefined;
}

function setToArray(values: Set<string>): string[] {
  const output: string[] = [];
  values.forEach((value: string) => output.push(value));
  return output;
}
