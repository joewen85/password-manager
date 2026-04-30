import {
  CreateCredentialInput,
  CreateServerInput,
  CreateServiceInput,
  EncryptedPayloadRecord,
  MasterKeyRecord,
  SecuritySettings,
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
  SyncProviderType,
  SyncSettings,
} from '../sync/SyncTypes';
import {
  PresignedUrlSyncClient,
  RemoteSyncClient,
  WebDavSyncClient,
} from '../sync/RemoteSyncClient';
import { VaultStore } from '../storage/VaultStore';

interface VaultRuntimePayload extends VaultPayloadRecord {
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
  createdAt: string;
  updatedAt: string;
  payload: object;
}

interface ExportSingleItemRecord {
  version: number;
  scope: string;
  exportedAt: string;
  item: ExportItemRecord;
}

interface ExportCategoryRecord {
  version: number;
  scope: string;
  exportedAt: string;
  category: string;
  count: number;
  items: ExportItemRecord[];
}

interface ImportSingleItemRecord {
  scope?: string;
  item?: ExportItemRecord;
}

interface ImportCategoryRecord {
  scope?: string;
  items?: ExportItemRecord[];
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
  payload?: EntryPayloadCarrier;
  isDeleted?: boolean;
  createdAt?: number;
  updatedAt?: number;
  label?: string;
}

interface AccessKeyCarrier {
  accessKey?: string;
  accessToken?: string;
}

const MAX_UNLOCK_ATTEMPTS: number = 5;
const LOCKOUT_DURATION_MS: number = 5 * 60 * 1000;

export class VaultController {
  private static readonly SCHEMA_VERSION: number = 1;

  private readonly store: VaultStore;
  private readonly crypto: VaultCryptoService;
  private readonly totp: TotpService;
  private snapshot: VaultRuntimePayload = createEmptyPayload();
  private masterKeyRecord: MasterKeyRecord | null = null;
  private sessionKeyToken: string | null = null;
  private unlockGuard: UnlockGuardState = defaultUnlockGuardState();
  private lastUnlockError: string = '';
  private unlocked: boolean = false;
  private syncInProgress: boolean = false;

  constructor(store: VaultStore, crypto: VaultCryptoService) {
    this.store = store;
    this.crypto = crypto;
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

  getEntries(): VaultEntry[] {
    const visible = this.snapshot.entries.filter(
      (entry: VaultEntry) => !entry.isDeleted,
    );
    visible.sort((a: VaultEntry, b: VaultEntry) => b.updatedAt - a.updatedAt);
    return visible.map((entry: VaultEntry) => deepCopyEntry(entry));
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
      return entry.tags.some((entryTag: string) =>
        entryTag.toLowerCase().includes(q)
      );
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

  lock(): void {
    this.unlocked = false;
    this.sessionKeyToken = null;
    this.snapshot = createEmptyPayload();
    this.syncInProgress = false;
  }

  async updateSyncSettings(settings: SyncSettings): Promise<void> {
    this.ensureUnlocked();
    this.snapshot.syncSettings = normalizeSyncSettings(settings);
    await this.persist();
  }

  async updateSecuritySettings(settings: SecuritySettings): Promise<void> {
    this.ensureUnlocked();
    this.snapshot.security = normalizeSecuritySettings(settings);
    await this.persist();
  }

  async syncNow(): Promise<void> {
    this.ensureUnlocked();
    if (this.syncInProgress) {
      return;
    }

    const localSettings = this.snapshot.syncSettings;
    if (localSettings.providerType === SyncProviderType.NONE) {
      this.recordSyncStatus('skipped', '未配置同步', localSettings.lastSyncRevision);
      await this.persist();
      return;
    }

    const client = this.buildSyncClient(localSettings);
    if (client === null) {
      this.recordSyncStatus('error', '同步配置不完整', localSettings.lastSyncRevision);
      await this.persist();
      return;
    }

    this.syncInProgress = true;
    try {
      let mergedPayload = deepCopyRuntimePayload(this.snapshot);
      let remoteRevision = localSettings.lastSyncRevision;
      let mergedMasterKey = this.masterKeyRecord;

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
        await this.persist();
        return;
      }

      mergedPayload.syncSettings = cloneSyncSettings(localSettings);
      const nextRevision =
        Math.max(localSettings.lastSyncRevision, remoteRevision) + 1;
      const payload = await this.buildSyncPayload(
        mergedPayload,
        nextRevision,
        mergedPayload.syncSettings,
        mergedMasterKey,
      );

      const upload = await client.upload(payload);
      if (upload.statusCode < 200 || upload.statusCode >= 300) {
        this.snapshot = mergedPayload;
        this.masterKeyRecord = mergedMasterKey;
        this.recordSyncStatus(
          'error',
          `上传失败(${upload.statusCode})`,
          localSettings.lastSyncRevision,
        );
        await this.persist();
        return;
      }

      this.snapshot = mergedPayload;
      this.masterKeyRecord = mergedMasterKey;
      this.recordSyncStatus(
        'success',
        `同步完成：修订${nextRevision}，条目${mergedPayload.entries.length}项`,
        nextRevision,
      );
      await this.persist();
    } catch (error) {
      this.recordSyncStatus(
        'error',
        `同步失败: ${error}`,
        this.snapshot.syncSettings.lastSyncRevision,
      );
      await this.persist();
    } finally {
      this.syncInProgress = false;
    }
  }

  async addCredential(input: CreateCredentialInput): Promise<void> {
    this.ensureUnlocked();
    const now = Date.now();
    const tags = normalizeTags(input.tags);
    this.snapshot.entries.push({
      id: nextId(),
      label: input.label.trim(),
      type: VaultEntryType.CREDENTIAL,
      payload: {
        username: input.username,
        password: input.password,
        token: input.token,
        appId: input.appId,
        accessKey: input.accessKey,
        secretKey: input.secretKey,
        notes: input.notes,
        tags,
        category: input.category.trim(),
      },
      tags,
      createdAt: now,
      updatedAt: now,
      isDeleted: false,
    });
    this.mergeCategories([input.category.trim()]);
    this.mergeTags(tags);
    await this.persist();
  }

  async addServer(input: CreateServerInput): Promise<void> {
    this.ensureUnlocked();
    const now = Date.now();
    const tags = normalizeTags(input.tags);
    this.snapshot.entries.push({
      id: nextId(),
      label: input.label.trim(),
      type: VaultEntryType.SERVER,
      payload: {
        name: input.name,
        ipAddress: input.ipAddress,
        port: input.port,
        username: input.username,
        password: input.password,
        basicConfig: input.basicConfig,
        operatingSystem: input.operatingSystem,
        location: input.location,
        notes: input.notes,
        tags,
        category: input.category.trim(),
      },
      tags,
      createdAt: now,
      updatedAt: now,
      isDeleted: false,
    });
    this.mergeCategories([input.category.trim()]);
    this.mergeTags(tags);
    await this.persist();
  }

  async addService(input: CreateServiceInput): Promise<void> {
    this.ensureUnlocked();
    const now = Date.now();
    const tags = normalizeTags(input.tags);
    this.snapshot.entries.push({
      id: nextId(),
      label: input.label.trim(),
      type: VaultEntryType.SERVICE,
      payload: {
        name: input.name,
        connectionAddress: input.connectionAddress,
        connectionPort: input.connectionPort,
        accountId: input.accountId,
        serverIds: [...input.serverIds],
        accounts: [...input.accounts],
        notes: input.notes,
        tags,
        category: input.category.trim(),
      },
      tags,
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
    target.label = input.label.trim();
    target.payload = {
      username: input.username,
      password: input.password,
      token: input.token,
      appId: input.appId,
      accessKey: input.accessKey,
      secretKey: input.secretKey,
      notes: input.notes,
      tags,
      category: input.category.trim(),
    };
    target.tags = tags;
    target.updatedAt = Date.now();
    this.mergeCategories([input.category.trim()]);
    this.mergeTags(tags);
    await this.persist();
  }

  async updateServerEntry(entryId: string, input: CreateServerInput): Promise<void> {
    this.ensureUnlocked();
    const target = this.requireVisibleEntry(entryId, VaultEntryType.SERVER);
    const tags = normalizeTags(input.tags);
    target.label = input.label.trim();
    target.payload = {
      name: input.name,
      ipAddress: input.ipAddress,
      port: input.port,
      username: input.username,
      password: input.password,
      basicConfig: input.basicConfig,
      operatingSystem: input.operatingSystem,
      location: input.location,
      notes: input.notes,
      tags,
      category: input.category.trim(),
    };
    target.tags = tags;
    target.updatedAt = Date.now();
    this.mergeCategories([input.category.trim()]);
    this.mergeTags(tags);
    await this.persist();
  }

  async updateServiceEntry(entryId: string, input: CreateServiceInput): Promise<void> {
    this.ensureUnlocked();
    const target = this.requireVisibleEntry(entryId, VaultEntryType.SERVICE);
    const tags = normalizeTags(input.tags);
    target.label = input.label.trim();
    target.payload = {
      name: input.name,
      connectionAddress: input.connectionAddress,
      connectionPort: input.connectionPort,
      accountId: input.accountId,
      serverIds: [...input.serverIds],
      accounts: [...input.accounts],
      notes: input.notes,
      tags,
      category: input.category.trim(),
    };
    target.tags = tags;
    target.updatedAt = Date.now();
    this.mergeCategories([input.category.trim()]);
    this.mergeTags(tags);
    await this.persist();
  }

  async deleteEntry(entryId: string): Promise<void> {
    this.ensureUnlocked();
    const target = this.snapshot.entries.find(
      (entry: VaultEntry) => entry.id === entryId,
    );
    if (target === undefined) {
      return;
    }
    target.isDeleted = true;
    target.updatedAt = Date.now();
    await this.persist();
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

  async addCategory(category: string): Promise<void> {
    this.ensureUnlocked();
    const clean = category.trim();
    if (clean.length === 0 || this.snapshot.categories.includes(clean)) {
      return;
    }
    this.snapshot.categories.push(clean);
    this.snapshot.categories.sort((a: string, b: string) => a.localeCompare(b));
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
    this.snapshot.entries.forEach((entry: VaultEntry) => {
      if (entry.isDeleted) {
        return;
      }
      const category = this.entryCategory(entry);
      if (category !== from) {
        return;
      }
      this.setEntryCategory(entry, to);
      entry.updatedAt = Date.now();
    });
    await this.persist();
  }

  async deleteCategory(category: string): Promise<void> {
    this.ensureUnlocked();
    const clean = category.trim();
    this.snapshot.categories = this.snapshot.categories.filter(
      (entryCategory: string) => entryCategory !== clean,
    );
    this.snapshot.entries.forEach((entry: VaultEntry) => {
      if (entry.isDeleted) {
        return;
      }
      if (this.entryCategory(entry) !== clean) {
        return;
      }
      this.setEntryCategory(entry, '');
      entry.updatedAt = Date.now();
    });
    await this.persist();
  }

  exportSnapshot(): string {
    this.ensureUnlocked();
    const payload: ExportSnapshotRecord = {
      version: VaultController.SCHEMA_VERSION,
      exportedAt: new Date().toISOString(),
      tags: this.snapshot.tags,
      categories: this.snapshot.categories,
      entries: this.snapshot.entries,
      masterKeyRecord: this.masterKeyRecord,
      security: this.snapshot.security,
      syncSettings: this.snapshot.syncSettings,
    };
    return JSON.stringify(payload, null, 2);
  }

  exportEntryData(entryId: string): string {
    this.ensureUnlocked();
    const entry = this.snapshot.entries.find(
      (value: VaultEntry) => value.id === entryId && !value.isDeleted,
    );
    if (entry === undefined) {
      throw new Error('条目不存在或已删除');
    }
    const payload: ExportSingleItemRecord = {
      version: VaultController.SCHEMA_VERSION,
      scope: 'item',
      exportedAt: new Date().toISOString(),
      item: this.buildExportItem(entry),
    };
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
    const payload: ExportCategoryRecord = {
      version: VaultController.SCHEMA_VERSION,
      scope: 'category',
      exportedAt: new Date().toISOString(),
      category: clean,
      count: items.length,
      items: items,
    };
    return JSON.stringify(payload, null, 2);
  }

  async importEntryData(contents: string): Promise<number> {
    const result = await this.applyImportPlan(
      await this.buildImportPlan(contents, 'item'),
      ImportConflictStrategy.KEEP_COPY,
    );
    return result.createdCount + result.updatedCount;
  }

  async importCategoryData(contents: string): Promise<number> {
    const result = await this.applyImportPlan(
      await this.buildImportPlan(contents, 'category'),
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
    return this.applyImportPlan(await this.buildImportPlan(contents, 'item'), strategy);
  }

  async importCategoryDataWithStrategy(
    contents: string,
    strategy: ImportConflictStrategy,
  ): Promise<ImportExecutionResult> {
    return this.applyImportPlan(await this.buildImportPlan(contents, 'category'), strategy);
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
    categories
      .map((category: string) => category.trim())
      .filter((category: string) => category.length > 0)
      .forEach((category: string) => union.add(category));
    const mergedCategories = setToArray(union);
    mergedCategories.sort((a: string, b: string) => a.localeCompare(b));
    this.snapshot.categories = mergedCategories;
  }

  private entryCategory(entry: VaultEntry): string {
    return resolveEntryCategory(entry);
  }

  private scheduleAutoSyncAfterUnlock(): void {
    this.syncNow().catch(() => {
      console.error('Auto sync after unlock failed');
    });
  }

  private buildExportItem(entry: VaultEntry): ExportItemRecord {
    return {
      id: entry.id,
      label: entry.label,
      type: entry.type,
      category: this.entryCategory(entry),
      createdAt: new Date(entry.createdAt).toISOString(),
      updatedAt: new Date(entry.updatedAt).toISOString(),
      payload: JSON.parse(JSON.stringify(entry.payload)) as object,
    };
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
        previewIdMap.set(item.id, existing.id);
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
    for (let index = 0; index < items.length; index++) {
      const current = items[index];
      if (current.disposition === 'create') {
        const createdId = await this.createImportedItem(current.item, idMap);
        createdCount += 1;
        if (current.item.id.length > 0) {
          idMap.set(current.item.id, createdId);
        }
        continue;
      }
      if (current.disposition === 'exactDuplicate') {
        skippedCount += 1;
        if (current.existing !== undefined && current.item.id.length > 0) {
          idMap.set(current.item.id, current.existing.id);
        }
        continue;
      }
      if (strategy === ImportConflictStrategy.SKIP) {
        skippedCount += 1;
        if (current.existing !== undefined && current.item.id.length > 0) {
          idMap.set(current.item.id, current.existing.id);
        }
        continue;
      }
      if (strategy === ImportConflictStrategy.OVERWRITE && current.existing !== undefined) {
        await this.updateImportedItem(current.existing, current.item, idMap);
        updatedCount += 1;
        if (current.item.id.length > 0) {
          idMap.set(current.item.id, current.existing.id);
        }
        continue;
      }
      const createdId = await this.createImportedItem(current.item, idMap);
      createdCount += 1;
      if (current.item.id.length > 0) {
        idMap.set(current.item.id, createdId);
      }
    }
    return {
      totalCount: items.length,
      createdCount,
      updatedCount,
      skippedCount,
    };
  }

  private parseImportItems(contents: string, scope: string): ExportItemRecord[] {
    const parsed = JSON.parse(contents) as ImportSingleItemRecord | ImportCategoryRecord;
    if (scope === 'item') {
      const single = parsed as ImportSingleItemRecord;
      if (single.scope !== 'item' || single.item === undefined) {
        throw new Error('不是单条条目导出 JSON');
      }
      return [single.item];
    }
    const category = parsed as ImportCategoryRecord;
    if (category.scope !== 'category' || category.items === undefined) {
      throw new Error('不是分类导出 JSON');
    }
    return category.items;
  }

  private findImportTarget(item: ExportItemRecord): VaultEntry | undefined {
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
    const normalizedIncoming = JSON.stringify(this.resolveImportedPayload(item, idMap));
    const normalizedExisting = JSON.stringify(existing.payload);
    return normalizedIncoming === normalizedExisting;
  }

  private async createImportedItem(
    item: ExportItemRecord,
    idMap: Map<string, string> = new Map<string, string>(),
  ): Promise<string> {
    if (item.type === VaultEntryType.CREDENTIAL) {
      const payload = item.payload as CreateCredentialInput;
      await this.addCredential({
        label: item.label,
        username: payload.username ?? '',
        password: payload.password ?? '',
        token: payload.token ?? '',
        appId: payload.appId ?? '',
        accessKey: resolveAccessKey(payload as AccessKeyCarrier),
        secretKey: payload.secretKey ?? '',
        notes: payload.notes ?? '',
        tags: payload.tags ?? [],
        category: payload.category ?? item.category ?? '',
      });
      return this.snapshot.entries[this.snapshot.entries.length - 1].id;
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
        basicConfig: payload.basicConfig ?? '',
        operatingSystem: payload.operatingSystem ?? '',
        location: payload.location ?? '',
        notes: payload.notes ?? '',
        tags: payload.tags ?? [],
        category: payload.category ?? item.category ?? '',
      });
      return this.snapshot.entries[this.snapshot.entries.length - 1].id;
    }
    if (item.type === VaultEntryType.SERVICE) {
      const payload = item.payload as CreateServiceInput;
      await this.addService({
        label: item.label,
        name: payload.name ?? '',
        connectionAddress: payload.connectionAddress ?? '',
        connectionPort: payload.connectionPort ?? '',
        accountId: idMap.get(payload.accountId ?? '') ?? (payload.accountId ?? ''),
        serverIds: (payload.serverIds ?? []).map(
          (entryId: string) => idMap.get(entryId) ?? entryId,
        ),
        accounts: payload.accounts ?? [],
        notes: payload.notes ?? '',
        tags: payload.tags ?? [],
        category: payload.category ?? item.category ?? '',
      });
      return this.snapshot.entries[this.snapshot.entries.length - 1].id;
    }
    throw new Error(`不支持的条目类型: ${item.type}`);
  }

  private async updateImportedItem(
    existing: VaultEntry,
    item: ExportItemRecord,
    idMap: Map<string, string>,
  ): Promise<void> {
    const resolved = this.resolveImportedPayload(item, idMap);
    if (existing.type === VaultEntryType.CREDENTIAL) {
      const payload = resolved as CreateCredentialInput;
      await this.updateCredentialEntry(existing.id, {
        label: item.label,
        username: payload.username ?? '',
        password: payload.password ?? '',
        token: payload.token ?? '',
        appId: payload.appId ?? '',
        accessKey: resolveAccessKey(payload as AccessKeyCarrier),
        secretKey: payload.secretKey ?? '',
        notes: payload.notes ?? '',
        tags: payload.tags ?? [],
        category: payload.category ?? item.category ?? '',
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
        basicConfig: payload.basicConfig ?? '',
        operatingSystem: payload.operatingSystem ?? '',
        location: payload.location ?? '',
        notes: payload.notes ?? '',
        tags: payload.tags ?? [],
        category: payload.category ?? item.category ?? '',
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
      accounts: payload.accounts ?? [],
      notes: payload.notes ?? '',
      tags: payload.tags ?? [],
      category: payload.category ?? item.category ?? '',
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
    payload.accountId = idMap.get(payload.accountId ?? '') ?? (payload.accountId ?? '');
    payload.serverIds = (payload.serverIds ?? []).map(
      (entryId: string) => idMap.get(entryId) ?? entryId,
    );
    return payload as object;
  }

  private requireVisibleEntry(entryId: string, type: VaultEntryType): VaultEntry {
    const target = this.snapshot.entries.find(
      (entry: VaultEntry) => entry.id === entryId && !entry.isDeleted && entry.type === type,
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

  private async persist(): Promise<void> {
    this.ensureUnlocked();
    const sessionKey = this.sessionKeyToken;
    if (sessionKey === null) {
      throw new Error('Session key is missing');
    }
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
    const encryptedVault = await this.crypto.encryptString(
      JSON.stringify(payload),
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
    local.entries.forEach((entry: VaultEntry) => localMap.set(entry.id, deepCopyEntry(entry)));

    const remoteMap = new Map<string, VaultEntry>();
    remote.entries.forEach((entry: VaultEntry) => remoteMap.set(entry.id, deepCopyEntry(entry)));

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

    const tags = new Set<string>();
    const categories = new Set<string>();
    local.tags.forEach((tag: string) => tags.add(tag));
    remote.tags.forEach((tag: string) => tags.add(tag));
    local.categories.forEach((category: string) => categories.add(category));
    remote.categories.forEach((category: string) => categories.add(category));
    mergedEntries.forEach((entry: VaultEntry) => {
      entry.tags.forEach((tag: string) => tags.add(tag));
      const category = this.entryCategory(entry);
      if (category.length > 0) {
        categories.add(category);
      }
    });

    return {
      tags: normalizeTags(setToArray(tags)),
      categories: normalizeTags(setToArray(categories)),
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
  ): void {
    const settings = cloneSyncSettings(this.snapshot.syncSettings);
    const safeMessage = sanitizeLogMessage(message);
    const now = Date.now();
    settings.lastSyncAt = now;
    settings.lastSyncStatus = status;
    settings.lastSyncMessage = safeMessage;
    settings.lastSyncRevision = revision;

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
    entries: [],
    security: defaultSecuritySettings(),
    updatedAt: Date.now(),
    syncSettings: defaultSyncSettings(),
  };
}

function sanitizeRuntimePayload(
  input: VaultPayloadRecord | VaultRuntimePayload,
): VaultRuntimePayload {
  const runtimePayload = input as VaultRuntimePayload;
  const maybeSettings = hasSyncSettings(input) ? runtimePayload.syncSettings : undefined;
  const maybeSecurity = input.security;
  const normalizedEntries = (input.entries ?? []).map((entry: VaultEntry) =>
    normalizeRuntimeEntry(entry),
  );
  const tagUnion = new Set<string>();
  const categoryUnion = new Set<string>();
  normalizeTags(input.tags ?? []).forEach((tag: string) => tagUnion.add(tag));
  normalizeTags(input.categories ?? []).forEach((category: string) =>
    categoryUnion.add(category),
  );
  normalizedEntries.forEach((entry: VaultEntry) => {
    entry.tags.forEach((tag: string) => tagUnion.add(tag));
    const category = resolveEntryCategory(entry);
    if (category.length > 0) {
      categoryUnion.add(category);
    }
  });
  return {
    tags: normalizeTags(setToArray(tagUnion)),
    categories: normalizeTags(setToArray(categoryUnion)),
    entries: normalizedEntries,
    security: normalizeSecuritySettings(maybeSecurity),
    updatedAt: typeof input.updatedAt === 'number' ? input.updatedAt : Date.now(),
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
  carrier.payload = payload;
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
  return normalized;
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
    autoSyncEnabled: settings.autoSyncEnabled,
    autoSyncIntervalMinutes: settings.autoSyncIntervalMinutes,
    autoSyncOnUnlock: settings.autoSyncOnUnlock,
    conflictStrategy: settings.conflictStrategy,
    syncMasterKey: settings.syncMasterKey,
    deviceId: settings.deviceId,
    lastSyncRevision: settings.lastSyncRevision,
    lastSyncAt: settings.lastSyncAt,
    lastSyncStatus: settings.lastSyncStatus,
    lastSyncMessage: settings.lastSyncMessage,
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

function defaultSecuritySettings(): SecuritySettings {
  return {
    requireTotp: false,
    totpSecret: '',
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
  };
}

function cloneSecuritySettings(settings: SecuritySettings): SecuritySettings {
  return {
    requireTotp: settings.requireTotp,
    totpSecret: settings.totpSecret,
  };
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

function nextId(): string {
  const ts = Date.now().toString(36);
  const rand = Math.floor(Math.random() * 1_000_000_000).toString(36);
  return `${ts}-${rand}`;
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
