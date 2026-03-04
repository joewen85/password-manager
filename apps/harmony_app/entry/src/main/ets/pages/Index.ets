import { promptAction } from '@kit.ArkUI';
import { Context } from '@kit.AbilityKit';
import {
  CreateCredentialInput,
  CreateServerInput,
  CreateServiceInput,
  CredentialPayload,
  SecuritySettings,
  ServerPayload,
  ServicePayload,
  VaultEntry,
  VaultEntryType
} from '../src/model/VaultTypes';
import { VaultController } from '../src/service/VaultController';
import { VaultCryptoService } from '../src/security/VaultCryptoService';
import { InMemoryVaultStore, PreferencesVaultStore } from '../src/storage/VaultStore';
import { ConflictStrategy, SyncProviderType, SyncSettings } from '../src/sync/SyncTypes';

type DraftType = 'credential' | 'server' | 'service';
const MAX_UNLOCK_ATTEMPTS: number = 5;

@Entry
@Component
struct Index {
  private vaultController: VaultController | null = null;

  @State private ready: boolean = false;
  @State private hasMasterKey: boolean = false;
  @State private unlocked: boolean = false;

  @State private password: string = '';
  @State private confirmPassword: string = '';
  @State private unlockTotpCode: string = '';
  @State private unlockRemainingSeconds: number = 0;
  @State private unlockFailedAttempts: number = 0;
  @State private syncBusy: boolean = false;
  @State private syncProviderType: SyncProviderType = SyncProviderType.NONE;
  @State private syncConflictStrategy: ConflictStrategy = ConflictStrategy.REMOTE_WINS;
  @State private syncWebdavUrl: string = '';
  @State private syncWebdavUsername: string = '';
  @State private syncWebdavPassword: string = '';
  @State private syncWebdavPath: string = '/vault.json';
  @State private syncPresignedDownloadUrl: string = '';
  @State private syncPresignedUploadUrl: string = '';
  @State private syncStatus: string = '未同步';
  @State private syncRevision: number = 0;
  @State private syncLogs: string[] = [];
  @State private securityRequireTotp: boolean = false;
  @State private securityTotpSecret: string = '';

  @State private searchQuery: string = '';
  @State private selectedType: string = 'all';
  @State private selectedTag: string = '';

  @State private entries: VaultEntry[] = [];
  @State private tags: string[] = [];

  @State private tagDraft: string = '';

  @State private draftType: DraftType = 'credential';
  @State private draftLabel: string = '';
  @State private draftTags: string = '';

  @State private draftCredentialUsername: string = '';
  @State private draftCredentialPassword: string = '';

  @State private draftServerName: string = '';
  @State private draftServerIp: string = '';
  @State private draftServerPort: string = '';

  @State private draftServiceName: string = '';
  @State private draftServiceAddress: string = '';
  @State private draftServicePort: string = '';

  async aboutToAppear(): Promise<void> {
    const crypto = new VaultCryptoService();
    try {
      const hostContext = this.getUIContext().getHostContext() as Context;
      const persistentStore = await PreferencesVaultStore.create(hostContext);
      this.vaultController = new VaultController(persistentStore, crypto);
    } catch (error) {
      console.error(`Preferences store unavailable, fallback to memory: ${error}`);
      this.vaultController = new VaultController(new InMemoryVaultStore(), crypto);
    }
    await this.controller().initialize();
    this.hasMasterKey = this.controller().hasMasterKey();
    this.unlocked = this.controller().isUnlocked();
    this.refreshUnlockGuardState();
    this.refreshData();
    if (this.unlocked) {
      this.refreshSecurityState();
      this.refreshSyncState();
    }
    this.ready = true;
  }

  build() {
    Column() {
      if (!this.ready) {
        Text('正在加载...').fontSize(18).fontWeight(FontWeight.Medium);
      } else if (!this.unlocked) {
        this.UnlockView();
      } else {
        this.VaultView();
      }
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor('#F4F6F0');
  }

  @Builder
  private UnlockView() {
    Column({ space: 12 }) {
      Text(this.hasMasterKey ? '解锁密码库' : '初始化密码库')
        .fontSize(26)
        .fontWeight(FontWeight.Bold);

      Text(this.hasMasterKey ? '请输入主密码继续。' : '首次使用，请设置主密码。')
        .fontSize(14)
        .fontColor('#566060');

      TextInput({ placeholder: '主密码', text: $$this.password })
        .type(InputType.Password)
        .width('100%')
        .height(48)
        .backgroundColor('#FFFFFF')
        .borderRadius(12)
        .padding({ left: 12, right: 12 });

      if (!this.hasMasterKey) {
        TextInput({ placeholder: '确认主密码', text: $$this.confirmPassword })
          .type(InputType.Password)
          .width('100%')
          .height(48)
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .padding({ left: 12, right: 12 });
      }

      if (this.hasMasterKey) {
        TextInput({ placeholder: '动态验证码(启用2FA后必填)', text: $$this.unlockTotpCode })
          .type(InputType.Number)
          .width('100%')
          .height(48)
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .padding({ left: 12, right: 12 });

        if (this.unlockRemainingSeconds > 0) {
          Text(`解锁暂时受限，请在 ${this.unlockRemainingSeconds} 秒后重试`)
            .fontSize(12)
            .fontColor('#9A4D4D');
        } else if (this.unlockFailedAttempts > 0) {
          Text(`剩余尝试次数 ${this.remainingUnlockAttempts()} 次`)
            .fontSize(12)
            .fontColor('#9A4D4D');
        }
      }

      Button(this.hasMasterKey ? '解锁' : '初始化')
        .type(ButtonType.Capsule)
        .width('100%')
        .height(44)
        .onClick(() => {
          this.onUnlockSubmit();
        });
    }
    .width('100%')
    .constraintSize({ maxWidth: 520 })
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center);
  }

  @Builder
  private VaultView() {
    Column({ space: 12 }) {
      this.HeaderSection();
      this.SecuritySection();
      this.SyncSection();
      this.FilterSection();
      this.NewEntrySection();
      this.TagSection();
      this.EntryListSection();
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  private HeaderSection() {
    Row() {
      Text('密码管理器（鸿蒙版MVP）').fontSize(22).fontWeight(FontWeight.Bold);
      Blank();
      Button('锁定')
        .type(ButtonType.Normal)
        .onClick(() => {
          this.controller().lock();
          this.unlocked = false;
          this.password = '';
          this.confirmPassword = '';
          this.unlockTotpCode = '';
          this.syncBusy = false;
          this.syncStatus = '未同步';
          this.syncLogs = [];
          this.refreshUnlockGuardState();
        });
    }
    .width('100%');
  }

  @Builder
  private SecuritySection() {
    Column({ space: 8 }) {
      Text('安全设置').fontSize(18).fontWeight(FontWeight.Medium);

      Row({ space: 8 }) {
        Button('关闭2FA')
          .onClick(() => this.securityRequireTotp = false)
          .backgroundColor(this.securityRequireTotp ? '#CED8D9' : '#2F7F79');
        Button('开启2FA')
          .onClick(() => this.securityRequireTotp = true)
          .backgroundColor(this.securityRequireTotp ? '#2F7F79' : '#CED8D9');
      }

      TextInput({ placeholder: 'TOTP Secret (Base32)', text: $$this.securityTotpSecret })
        .width('100%')
        .height(42)
        .backgroundColor('#FFFFFF')
        .borderRadius(10)
        .padding({ left: 10, right: 10 });

      Button('保存安全设置')
        .type(ButtonType.Capsule)
        .width('100%')
        .onClick(() => {
          this.onSaveSecuritySettings();
        });

      Text(this.securityRequireTotp ? '解锁时将强制校验动态验证码。' : '当前未启用2FA。')
        .fontSize(12)
        .fontColor('#5A6668');
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#EAF0EE')
    .borderRadius(16);
  }

  @Builder
  private SyncSection() {
    Column({ space: 8 }) {
      Row() {
        Text('同步设置').fontSize(18).fontWeight(FontWeight.Medium);
        Blank();
        Text(`修订 ${this.syncRevision}`).fontSize(12).fontColor('#6F7A7C');
      }

      Row({ space: 8 }) {
        Button('关闭')
          .onClick(() => this.syncProviderType = SyncProviderType.NONE)
          .backgroundColor(this.syncProviderType === SyncProviderType.NONE ? '#0F4C5C' : '#CED8D9');
        Button('WebDAV')
          .onClick(() => this.syncProviderType = SyncProviderType.WEBDAV)
          .backgroundColor(
            this.syncProviderType === SyncProviderType.WEBDAV ||
            this.syncProviderType === SyncProviderType.NAS_WEBDAV
              ? '#0F4C5C'
              : '#CED8D9',
          );
        Button('S3链接')
          .onClick(() => this.syncProviderType = SyncProviderType.S3_PRESIGNED)
          .backgroundColor(this.syncProviderType === SyncProviderType.S3_PRESIGNED ? '#0F4C5C' : '#CED8D9');
      }

      if (
        this.syncProviderType === SyncProviderType.WEBDAV ||
        this.syncProviderType === SyncProviderType.NAS_WEBDAV
      ) {
        TextInput({ placeholder: 'WebDAV 地址', text: $$this.syncWebdavUrl })
          .width('100%')
          .height(42)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 });
        TextInput({ placeholder: 'WebDAV 路径(/vault.json)', text: $$this.syncWebdavPath })
          .width('100%')
          .height(42)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 });
        TextInput({ placeholder: '用户名(可选)', text: $$this.syncWebdavUsername })
          .width('100%')
          .height(42)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 });
        TextInput({ placeholder: '密码(可选)', text: $$this.syncWebdavPassword })
          .type(InputType.Password)
          .width('100%')
          .height(42)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 });
      }

      if (this.syncProviderType === SyncProviderType.S3_PRESIGNED) {
        TextInput({ placeholder: '下载 URL', text: $$this.syncPresignedDownloadUrl })
          .width('100%')
          .height(42)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 });
        TextInput({ placeholder: '上传 URL', text: $$this.syncPresignedUploadUrl })
          .width('100%')
          .height(42)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 });
      }

      Row({ space: 8 }) {
        Text('冲突策略').fontSize(12).fontColor('#6F7A7C');
        Button('远端优先')
          .onClick(() => this.syncConflictStrategy = ConflictStrategy.REMOTE_WINS)
          .backgroundColor(this.syncConflictStrategy === ConflictStrategy.REMOTE_WINS ? '#2F7F79' : '#CED8D9');
        Button('本地优先')
          .onClick(() => this.syncConflictStrategy = ConflictStrategy.LOCAL_WINS)
          .backgroundColor(this.syncConflictStrategy === ConflictStrategy.LOCAL_WINS ? '#2F7F79' : '#CED8D9');
        Button('保留冲突')
          .onClick(() => this.syncConflictStrategy = ConflictStrategy.KEEP_BOTH)
          .backgroundColor(this.syncConflictStrategy === ConflictStrategy.KEEP_BOTH ? '#2F7F79' : '#CED8D9');
      }

      Row({ space: 8 }) {
        Button('保存同步设置')
          .type(ButtonType.Capsule)
          .layoutWeight(1)
          .onClick(() => {
            this.onSaveSyncSettings();
          });
        Button(this.syncBusy ? '同步中...' : '立即同步')
          .type(ButtonType.Capsule)
          .layoutWeight(1)
          .onClick(() => {
            if (this.syncBusy) {
              return;
            }
            this.onSyncNow();
          });
      }

      Text(this.syncStatus).fontSize(12).fontColor('#5A6668');

      if (this.syncLogs.length > 0) {
        Column({ space: 4 }) {
          ForEach(this.syncLogs, (line: string) => {
            Text(line).fontSize(11).fontColor('#6F7A7C').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
          }, (line: string, index: number) => `${line}-${index}`);
        }
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#EAF0EE')
    .borderRadius(16);
  }

  @Builder
  private FilterSection() {
    Column({ space: 8 }) {
      TextInput({ placeholder: '搜索标题/标签', text: $$this.searchQuery })
        .width('100%')
        .height(44)
        .backgroundColor('#FFFFFF')
        .borderRadius(12)
        .padding({ left: 12, right: 12 });

      Row({ space: 8 }) {
        Button('全部').onClick(() => this.selectedType = 'all').backgroundColor(this.selectedType === 'all' ? '#0F4C5C' : '#CED8D9');
        Button('账号').onClick(() => this.selectedType = 'credential').backgroundColor(this.selectedType === 'credential' ? '#0F4C5C' : '#CED8D9');
        Button('服务器').onClick(() => this.selectedType = 'server').backgroundColor(this.selectedType === 'server' ? '#0F4C5C' : '#CED8D9');
        Button('服务').onClick(() => this.selectedType = 'service').backgroundColor(this.selectedType === 'service' ? '#0F4C5C' : '#CED8D9');
      }
      .width('100%');
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#EAF0EE')
    .borderRadius(16);
  }

  @Builder
  private NewEntrySection() {
    Column({ space: 8 }) {
      Text('新建条目').fontSize(18).fontWeight(FontWeight.Medium);

      Row({ space: 8 }) {
        Button('账号').onClick(() => this.draftType = 'credential').backgroundColor(this.draftType === 'credential' ? '#2F7F79' : '#CED8D9');
        Button('服务器').onClick(() => this.draftType = 'server').backgroundColor(this.draftType === 'server' ? '#2F7F79' : '#CED8D9');
        Button('服务').onClick(() => this.draftType = 'service').backgroundColor(this.draftType === 'service' ? '#2F7F79' : '#CED8D9');
      }

      TextInput({ placeholder: '标题（必填）', text: $$this.draftLabel })
        .width('100%')
        .height(42)
        .backgroundColor('#FFFFFF')
        .borderRadius(10)
        .padding({ left: 10, right: 10 });

      TextInput({ placeholder: '标签，逗号分隔', text: $$this.draftTags })
        .width('100%')
        .height(42)
        .backgroundColor('#FFFFFF')
        .borderRadius(10)
        .padding({ left: 10, right: 10 });

      if (this.draftType === 'credential') {
        TextInput({ placeholder: '用户名', text: $$this.draftCredentialUsername })
          .width('100%')
          .height(42)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 });
        TextInput({ placeholder: '密码', text: $$this.draftCredentialPassword })
          .type(InputType.Password)
          .width('100%')
          .height(42)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 });
      }

      if (this.draftType === 'server') {
        TextInput({ placeholder: '服务器名称', text: $$this.draftServerName })
          .width('100%')
          .height(42)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 });
        TextInput({ placeholder: 'IP地址', text: $$this.draftServerIp })
          .width('100%')
          .height(42)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 });
        TextInput({ placeholder: '端口', text: $$this.draftServerPort })
          .width('100%')
          .height(42)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 });
      }

      if (this.draftType === 'service') {
        TextInput({ placeholder: '服务名称', text: $$this.draftServiceName })
          .width('100%')
          .height(42)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 });
        TextInput({ placeholder: '连接地址', text: $$this.draftServiceAddress })
          .width('100%')
          .height(42)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 });
        TextInput({ placeholder: '端口', text: $$this.draftServicePort })
          .width('100%')
          .height(42)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 });
      }

      Button('保存条目')
        .type(ButtonType.Capsule)
        .width('100%')
        .onClick(() => {
          this.onCreateEntry();
        });
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#EAF0EE')
    .borderRadius(16);
  }

  @Builder
  private TagSection() {
    Column({ space: 8 }) {
      Text('标签管理').fontSize(18).fontWeight(FontWeight.Medium);

      Row({ space: 8 }) {
        TextInput({ placeholder: '新增标签', text: $$this.tagDraft })
          .layoutWeight(1)
          .height(42)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 });
        Button('添加').onClick(() => this.onAddTag());
      }

      if (this.tags.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.tags, (tag: string) => {
            Row({ space: 4 }) {
              Text(tag).fontSize(13);
              Button('x')
                .fontSize(11)
                .width(22)
                .height(22)
                .onClick(() => {
                  this.onDeleteTag(tag);
                });
            }
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .margin({ right: 6, bottom: 6 })
            .backgroundColor(this.selectedTag === tag ? '#BEE6D6' : '#FFFFFF')
            .borderRadius(999)
            .onClick(() => {
              this.selectedTag = this.selectedTag === tag ? '' : tag;
            });
          }, (tag: string) => tag);
        }
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#EAF0EE')
    .borderRadius(16);
  }

  @Builder
  private EntryListSection() {
    Column({ space: 8 }) {
      Row() {
        Text('条目列表').fontSize(18).fontWeight(FontWeight.Medium);
        Blank();
        Text(`共 ${this.filteredEntries().length} 条`).fontSize(12).fontColor('#687275');
      }

      List({ space: 8 }) {
        ForEach(this.filteredEntries(), (entry: VaultEntry) => {
          ListItem() {
            Column({ space: 6 }) {
              Row() {
                Text(entry.label).fontSize(16).fontWeight(FontWeight.Medium).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
                Blank();
                Text(this.typeLabel(entry.type)).fontSize(12).fontColor('#2F7F79');
              }

              Text(this.entrySummary(entry)).fontSize(12).fontColor('#5C6769').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
              Text(`标签: ${entry.tags.join(', ') || '-'}`).fontSize(11).fontColor('#6D787A').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });

              Row() {
                Text(new Date(entry.updatedAt).toLocaleString()).fontSize(11).fontColor('#7A8587');
                Blank();
                Button('删除')
                  .type(ButtonType.Normal)
                  .backgroundColor('#F3D7D7')
                  .fontColor('#8A2A2A')
                  .onClick(() => {
                    this.onDeleteEntry(entry.id);
                  });
              }
            }
            .width('100%')
            .padding(12)
            .backgroundColor('#FFFFFF')
            .borderRadius(12);
          }
        }, (entry: VaultEntry) => entry.id);
      }
      .layoutWeight(1)
      .width('100%');
    }
    .layoutWeight(1)
    .width('100%')
    .padding(12)
    .backgroundColor('#EAF0EE')
    .borderRadius(16);
  }

  private controller(): VaultController {
    if (this.vaultController === null) {
      throw new Error('VaultController not initialized');
    }
    return this.vaultController;
  }

  private async onUnlockSubmit(): Promise<void> {
    const password = this.password.trim();
    if (password.length === 0) {
      this.toast('请输入主密码');
      return;
    }
    if (!this.hasMasterKey) {
      const ok = await this.controller().setupMasterPassword(password, this.confirmPassword);
      if (!ok) {
        this.toast('初始化失败，请检查输入');
        return;
      }
      this.hasMasterKey = true;
      this.unlocked = true;
      this.password = '';
      this.confirmPassword = '';
      this.unlockTotpCode = '';
      this.refreshData();
      this.refreshSecurityState();
      this.refreshSyncState();
      this.refreshUnlockGuardState();
      this.toast('密码库已初始化');
      return;
    }

    const unlocked = await this.controller().unlock(password, this.unlockTotpCode);
    if (!unlocked) {
      this.refreshUnlockGuardState();
      this.toast(this.controller().getLastUnlockError());
      return;
    }
    this.unlocked = true;
    this.password = '';
    this.confirmPassword = '';
    this.unlockTotpCode = '';
    this.refreshData();
    this.refreshSecurityState();
    this.refreshSyncState();
    this.refreshUnlockGuardState();
  }

  private async onCreateEntry(): Promise<void> {
    const label = this.draftLabel.trim();
    if (label.length === 0) {
      this.toast('标题必填');
      return;
    }

    const tags = this.parseTags(this.draftTags);

    if (this.draftType === 'credential') {
      const input: CreateCredentialInput = {
        label: label,
        username: this.draftCredentialUsername.trim(),
        password: this.draftCredentialPassword,
        token: '',
        appId: '',
        accessToken: '',
        secretKey: '',
        notes: '',
        tags: tags
      };
      await this.controller().addCredential(input);
    }

    if (this.draftType === 'server') {
      const input: CreateServerInput = {
        label: label,
        name: this.draftServerName.trim(),
        ipAddress: this.draftServerIp.trim(),
        port: this.draftServerPort.trim(),
        username: '',
        password: '',
        basicConfig: '',
        operatingSystem: '',
        location: '',
        notes: '',
        tags: tags
      };
      await this.controller().addServer(input);
    }

    if (this.draftType === 'service') {
      const input: CreateServiceInput = {
        label: label,
        name: this.draftServiceName.trim(),
        connectionAddress: this.draftServiceAddress.trim(),
        connectionPort: this.draftServicePort.trim(),
        accountId: '',
        serverIds: [],
        accounts: [],
        notes: '',
        tags: tags
      };
      await this.controller().addService(input);
    }

    this.clearEntryDraft();
    this.refreshData();
    this.toast('已保存');
  }

  private async onDeleteEntry(entryId: string): Promise<void> {
    await this.controller().deleteEntry(entryId);
    this.refreshData();
  }

  private async onAddTag(): Promise<void> {
    if (this.tagDraft.trim().length === 0) {
      return;
    }
    await this.controller().addTag(this.tagDraft);
    this.tagDraft = '';
    this.refreshData();
  }

  private async onDeleteTag(tag: string): Promise<void> {
    await this.controller().deleteTag(tag);
    if (this.selectedTag === tag) {
      this.selectedTag = '';
    }
    this.refreshData();
  }

  private async onSaveSyncSettings(): Promise<void> {
    try {
      const current = this.controller().getSyncSettings();
      const updated: SyncSettings = {
        providerType: this.syncProviderType,
        webdavUrl: this.syncWebdavUrl.trim(),
        webdavUsername: this.syncWebdavUsername.trim(),
        webdavPassword: this.syncWebdavPassword,
        webdavPath: this.syncWebdavPath.trim(),
        presignedDownloadUrl: this.syncPresignedDownloadUrl.trim(),
        presignedUploadUrl: this.syncPresignedUploadUrl.trim(),
        autoSyncEnabled: current.autoSyncEnabled,
        autoSyncIntervalMinutes: current.autoSyncIntervalMinutes,
        autoSyncOnUnlock: current.autoSyncOnUnlock,
        conflictStrategy: this.syncConflictStrategy,
        syncMasterKey: current.syncMasterKey,
        deviceId: current.deviceId,
        lastSyncRevision: current.lastSyncRevision,
        lastSyncAt: current.lastSyncAt,
        lastSyncStatus: current.lastSyncStatus,
        lastSyncMessage: current.lastSyncMessage,
        logs: current.logs,
      };
      await this.controller().updateSyncSettings(updated);
      this.refreshSyncState();
      this.toast('同步设置已保存');
    } catch (error) {
      this.toast(`保存失败: ${error}`);
    }
  }

  private async onSyncNow(): Promise<void> {
    this.syncBusy = true;
    try {
      await this.controller().syncNow();
    } catch (error) {
      this.toast(`同步失败: ${error}`);
    } finally {
      this.refreshData();
      this.refreshSyncState();
      this.syncBusy = false;
    }
  }

  private async onSaveSecuritySettings(): Promise<void> {
    try {
      const secret = this.securityTotpSecret.trim().replace(/\s+/g, '').toUpperCase();
      if (this.securityRequireTotp && secret.length === 0) {
        this.toast('开启2FA时必须填写 TOTP Secret');
        return;
      }
      const settings: SecuritySettings = {
        requireTotp: this.securityRequireTotp,
        totpSecret: this.securityRequireTotp ? secret : '',
      };
      await this.controller().updateSecuritySettings(settings);
      this.refreshSecurityState();
      this.toast('安全设置已保存');
    } catch (error) {
      this.toast(`保存失败: ${error}`);
    }
  }

  private refreshData(): void {
    this.entries = this.controller().getEntries();
    this.tags = this.controller().getTags();
  }

  private refreshSyncState(): void {
    const settings = this.controller().getSyncSettings();
    this.syncProviderType = settings.providerType;
    this.syncConflictStrategy = settings.conflictStrategy;
    this.syncWebdavUrl = settings.webdavUrl;
    this.syncWebdavUsername = settings.webdavUsername;
    this.syncWebdavPassword = settings.webdavPassword;
    this.syncWebdavPath = settings.webdavPath;
    this.syncPresignedDownloadUrl = settings.presignedDownloadUrl;
    this.syncPresignedUploadUrl = settings.presignedUploadUrl;
    this.syncRevision = settings.lastSyncRevision;
    this.syncBusy = this.controller().isSyncing();
    if (settings.lastSyncStatus.trim().length === 0) {
      this.syncStatus = '未同步';
    } else {
      this.syncStatus = `${settings.lastSyncStatus}: ${settings.lastSyncMessage}`;
    }
    this.syncLogs = settings.logs
      .slice(0, 5)
      .map(
        (entry) =>
          `[${entry.level.toUpperCase()}] ${new Date(entry.timestamp).toLocaleString()} ${entry.message}`,
      );
  }

  private refreshSecurityState(): void {
    const settings = this.controller().getSecuritySettings();
    this.securityRequireTotp = settings.requireTotp;
    this.securityTotpSecret = settings.totpSecret;
  }

  private refreshUnlockGuardState(): void {
    const guard = this.controller().getUnlockGuardState();
    this.unlockFailedAttempts = guard.failedAttempts;
    this.unlockRemainingSeconds = this.controller().getLockRemainingSeconds();
  }

  private parseTags(raw: string): string[] {
    const items = raw.split(',').map((entry: string) => entry.trim()).filter((entry: string) => entry.length > 0);
    const unique = new Set<string>();
    items.forEach((item: string) => unique.add(item));
    const normalized: string[] = [];
    unique.forEach((item: string) => normalized.push(item));
    return normalized;
  }

  private clearEntryDraft(): void {
    this.draftLabel = '';
    this.draftTags = '';
    this.draftCredentialUsername = '';
    this.draftCredentialPassword = '';
    this.draftServerName = '';
    this.draftServerIp = '';
    this.draftServerPort = '';
    this.draftServiceName = '';
    this.draftServiceAddress = '';
    this.draftServicePort = '';
  }

  private remainingUnlockAttempts(): number {
    const left = MAX_UNLOCK_ATTEMPTS - this.unlockFailedAttempts;
    return left > 0 ? left : 0;
  }

  private filteredEntries(): VaultEntry[] {
    const query = this.searchQuery.trim().toLowerCase();
    const selectedTag = this.selectedTag.trim().toLowerCase();
    return this.entries.filter((entry: VaultEntry) => {
      if (this.selectedType !== 'all' && entry.type !== this.selectedType) {
        return false;
      }
      if (selectedTag.length > 0) {
        const matched = entry.tags.some((entryTag: string) => entryTag.toLowerCase() === selectedTag);
        if (!matched) {
          return false;
        }
      }
      if (query.length === 0) {
        return true;
      }
      if (entry.label.toLowerCase().includes(query)) {
        return true;
      }
      return entry.tags.some((entryTag: string) => entryTag.toLowerCase().includes(query));
    });
  }

  private typeLabel(type: VaultEntryType): string {
    if (type === VaultEntryType.CREDENTIAL) {
      return '账号';
    }
    if (type === VaultEntryType.SERVER) {
      return '服务器';
    }
    return '服务';
  }

  private entrySummary(entry: VaultEntry): string {
    if (entry.type === VaultEntryType.CREDENTIAL) {
      const payload = entry.payload as CredentialPayload;
      return `用户名: ${payload.username || '-'} `;
    }
    if (entry.type === VaultEntryType.SERVER) {
      const payload = entry.payload as ServerPayload;
      return `IP: ${payload.ipAddress || '-'} 端口: ${payload.port || '-'}`;
    }
    const payload = entry.payload as ServicePayload;
    return `地址: ${payload.connectionAddress || '-'} 端口: ${payload.connectionPort || '-'}`;
  }

  private toast(message: string): void {
    promptAction.showToast({ message: message, duration: 2000 });
  }
}
