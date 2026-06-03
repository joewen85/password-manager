import { Context } from '@kit.AbilityKit';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import {
  CreateCredentialInput,
  CreateServerInput,
  CreateServiceInput,
  CredentialPayload,
  CustomField,
  SecuritySettings,
  ServerPayload,
  ServicePayload,
  VaultEntry,
  VaultEntryType
} from '../src/model/VaultTypes';
import {
  ImportConflictStrategy,
  ImportPreviewRecord,
  VaultController,
} from '../src/service/VaultController';
import { VaultCryptoService } from '../src/security/VaultCryptoService';
import { BiometricCredentialStore } from '../src/security/BiometricCredentialStore';
import { InMemoryVaultStore, PreferencesVaultStore } from '../src/storage/VaultStore';
import {
  ConflictStrategy,
  SyncIntervalUnit,
  SyncProviderType,
  SyncSettings,
} from '../src/sync/SyncTypes';

type DraftType = 'credential' | 'server' | 'service';
type ActivePanel = 'home' | 'settings' | 'category' | 'tag';
const MAX_UNLOCK_ATTEMPTS: number = 5;
const UI_BACKGROUND: string = '#F4F6F8';
const UI_SURFACE: string = '#FFFFFF';
const UI_SURFACE_ALT: string = '#F8FAFC';
const UI_TEXT: string = '#181F2A';
const UI_MUTED: string = '#636F80';
const UI_STROKE: string = '#DAE1EA';
const UI_ACCENT: string = '#245DC4';
const UI_SELECTED: string = '#E8F0FF';
const UI_DANGER: string = '#B42318';
const UI_DANGER_SURFACE: string = '#FFF1F0';

interface SearchTerm {
  field: string;
  value: string;
}

interface SearchPayload {
  category?: string;
  metadataCategory?: string;
  name?: string;
  appId?: string;
  ipAddress?: string;
  port?: string;
  username?: string;
  password?: string;
  token?: string;
  accessKey?: string;
  secretKey?: string;
  notes?: string;
  connectionAddress?: string;
  connectionPort?: string;
  accountId?: string;
  serverIds?: string[];
  accounts?: SearchServiceAccount[];
}

interface SearchServiceAccount {
  username?: string;
  password?: string;
  note?: string;
}

interface EntryCategoryCarrier {
  category?: string;
  metadataCategory?: string;
}

interface ExportFieldOption {
  id: string;
  label: string;
}

@Entry
@Component
struct Index {
  private vaultController: VaultController | null = null;
  private biometricCredentialStore: BiometricCredentialStore | null = null;
  private hostContext: Context | null = null;
  private searchInputController: TextInputController = new TextInputController();
  private entryListScroller: Scroller = new Scroller();
  private autoSyncTimerId: number = -1;
  private idleLockTimerId: number = -1;
  private lastActivityAt: number = Date.now();
  private biometricAutoPrompted: boolean = false;

  @State private ready: boolean = false;
  @State private hasMasterKey: boolean = false;
  @State private unlocked: boolean = false;
  @State private activePanel: ActivePanel = 'home';
  @State private actionPanelVisible: boolean = false;
  @State private entryEditorVisible: boolean = false;

  @State private password: string = '';
  @State private confirmPassword: string = '';
  @State private unlockTotpCode: string = '';
  @State private unlockRemainingSeconds: number = 0;
  @State private unlockFailedAttempts: number = 0;
  @State private biometricUnlockAvailable: boolean = false;
  @State private biometricUnlockEnabled: boolean = false;
  @State private biometricUnlockRequested: boolean = false;
  @State private biometricFailureCount: number = 0;
  @State private biometricBusy: boolean = false;
  @State private syncBusy: boolean = false;
  @State private syncProviderType: SyncProviderType = SyncProviderType.NONE;
  @State private syncConflictStrategy: ConflictStrategy = ConflictStrategy.REMOTE_WINS;
  @State private syncWebdavUrl: string = '';
  @State private syncWebdavUsername: string = '';
  @State private syncWebdavPassword: string = '';
  @State private syncWebdavPath: string = '/vault.json';
  @State private syncPresignedDownloadUrl: string = '';
  @State private syncPresignedUploadUrl: string = '';
  @State private syncAutoEnabled: boolean = false;
  @State private syncAutoOnUnlock: boolean = true;
  @State private syncMasterKey: boolean = true;
  @State private syncIntervalValue: string = '30';
  @State private syncIntervalUnit: SyncIntervalUnit = SyncIntervalUnit.MINUTES;
  @State private syncDeviceId: string = '';
  @State private syncStatus: string = '未同步';
  @State private syncRevision: number = 0;
  @State private syncLogs: string[] = [];
  @State private securityRequireTotp: boolean = false;
  @State private securityTotpSecret: string = '';
  @State private securityIdleAutoLockMinutes: string = '0';
  @State private securityBiometricMasterPassword: string = '';
  @State private toastMessage: string = '';
  @State private toastVersion: number = 0;

  @State private searchQuery: string = '';
  @State private selectedCategory: string = '';
  @State private selectedTag: string = '';
  @State private entryListFirstVisibleIndex: number = 0;

  @State private entries: VaultEntry[] = [];
  @State private tags: string[] = [];
  @State private categories: string[] = [];

  @State private tagDraft: string = '';
  @State private categoryDraft: string = '';
  @State private categoryRenameSource: string = '';

  @State private draftType: DraftType = 'credential';
  @State private draftLabel: string = '';
  @State private draftCategory: string = '';
  @State private draftCategorySearch: string = '';
  @State private draftTagSearch: string = '';
  @State private draftSelectedTags: string[] = [];
  @State private draftCustomFields: CustomField[] = [];
  @State private editingEntryId: string = '';
  @State private exportEntryId: string = '';
  @State private exportSelectedFieldIds: string[] = [];

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
      this.hostContext = hostContext;
      const persistentStore = await PreferencesVaultStore.create(hostContext);
      this.vaultController = new VaultController(persistentStore, crypto);
      this.biometricCredentialStore = await BiometricCredentialStore.create(hostContext);
    } catch (error) {
      console.error(`Preferences store unavailable, fallback to memory: ${error}`);
      this.vaultController = new VaultController(new InMemoryVaultStore(), crypto);
      this.biometricCredentialStore = null;
    }
    await this.controller().initialize();
    this.hasMasterKey = this.controller().hasMasterKey();
    this.unlocked = this.controller().isUnlocked();
    this.refreshUnlockGuardState();
    await this.refreshBiometricState();
    this.refreshData();
    if (this.unlocked) {
      this.refreshSecurityState();
      this.refreshSyncState();
    }
    this.ready = true;
    this.configureAutoSyncTimer();
    this.configureIdleLockTimer();
    this.scheduleBiometricUnlockPrompt();
  }

  aboutToDisappear(): void {
    this.stopAutoSyncTimer();
    this.stopIdleLockTimer();
  }

  build() {
    Column() {
      if (this.toastMessage.length > 0) {
        this.ToastBanner();
      }
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
    .backgroundColor(UI_BACKGROUND)
    .onClick(() => {
      this.recordUserActivity();
    });
  }

  @Builder
  private ToastBanner() {
    Text(this.toastMessage)
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .margin({ bottom: 12 })
      .backgroundColor(UI_ACCENT)
      .fontColor('#FFFFFF')
      .fontSize(13)
      .borderRadius(12);
  }

  @Builder
  private UnlockView() {
    Column({ space: 12 }) {
      Text(this.hasMasterKey ? '解锁密码库' : '初始化密码库')
        .fontSize(26)
        .fontWeight(FontWeight.Bold);

      Text(this.hasMasterKey && this.biometricUnlockEnabled && this.biometricUnlockAvailable && this.biometricFailureCount < 3
        ? '正在调用生物识别；失败 3 次后请输入主密码。'
        : (this.hasMasterKey ? '请输入主密码继续。' : '首次使用，请设置主密码。'))
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

      if (this.hasMasterKey && this.biometricUnlockEnabled && this.biometricUnlockAvailable && this.biometricFailureCount > 0 && this.biometricFailureCount < 3) {
        Button(this.biometricBusy ? '正在验证...' : '重试生物识别')
          .type(ButtonType.Normal)
          .width('100%')
          .height(44)
          .enabled(!this.biometricBusy)
          .onClick(() => {
            this.onBiometricUnlock();
          });
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: 520 })
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center);
  }

  @Builder
  private VaultView() {
    Column({ space: 10 }) {
      this.HeaderSection();
      if (this.actionPanelVisible) {
        this.ActionPanel();
      }
      if (this.activePanel === 'settings') {
        this.SettingsPage();
      } else if (this.activePanel === 'category') {
        Scroll() {
          this.CategorySection();
        }
        .layoutWeight(1)
        .width('100%');
      } else if (this.activePanel === 'tag') {
        Scroll() {
          this.TagSection();
        }
        .layoutWeight(1)
        .width('100%');
      } else {
        this.StatusSummary();
        if (this.entryEditorVisible) {
          Scroll() {
            this.NewEntrySection();
          }
          .layoutWeight(1)
          .width('100%');
        } else {
          this.FilterSection();
          this.EntryListSection();
        }
      }
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  private HeaderSection() {
    Row({ space: 4 }) {
      Column({ space: 4 }) {
        Text('密码管理器')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_TEXT);
        Text('鸿蒙原生密码库')
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_ACCENT)
          .padding({ left: 9, right: 9, top: 4, bottom: 4 })
          .backgroundColor(UI_SURFACE_ALT)
          .borderRadius(999);
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start);
      Blank();
      this.ToolbarButton('+', true, () => {
        this.beginCreateEntry();
      });
      this.ToolbarButton(this.syncBusy ? '...' : '同步', false, () => {
        if (!this.syncBusy) {
          this.onSyncNow();
        }
      });
      this.ToolbarButton('设置', false, () => {
        this.activePanel = 'settings';
        this.entryEditorVisible = false;
        this.actionPanelVisible = false;
      });
      this.ToolbarButton('更多', false, () => {
        this.actionPanelVisible = !this.actionPanelVisible;
      });
      this.ToolbarButton('锁定', false, () => {
        this.lockVault();
      });
    }
    .width('100%')
    .padding({ left: 2, right: 2, top: 2, bottom: 2 });
  }

  @Builder
  private ToolbarButton(label: string, accent: boolean, action: () => void) {
    Text(label)
      .fontSize(label.length > 2 ? 11 : (label.length > 1 ? 12 : 18))
      .fontWeight(FontWeight.Bold)
      .fontColor(accent ? UI_ACCENT : UI_TEXT)
      .height(44)
      .constraintSize({ minWidth: 40 })
      .padding({ left: label.length > 1 ? 8 : 10, right: label.length > 1 ? 8 : 10 })
      .textAlign(TextAlign.Center)
      .backgroundColor(UI_SURFACE)
      .border({ width: 1, color: UI_STROKE })
      .borderRadius(14)
      .onClick(action);
  }

  @Builder
  private ActionPanel() {
    Column({ space: 10 }) {
      Row() {
        Text('快捷操作')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_TEXT);
        Blank();
        this.SmallGhostButton('关闭', () => {
          this.actionPanelVisible = false;
        });
      }
      Flex({ wrap: FlexWrap.Wrap }) {
        this.ActionChip('设置', false, () => {
          this.activePanel = 'settings';
          this.entryEditorVisible = false;
          this.actionPanelVisible = false;
        });
        this.ActionChip('分类管理', false, () => {
          this.activePanel = 'category';
          this.entryEditorVisible = false;
          this.actionPanelVisible = false;
        });
        this.ActionChip('标签管理', false, () => {
          this.activePanel = 'tag';
          this.entryEditorVisible = false;
          this.actionPanelVisible = false;
        });
        this.ActionChip('导入条目', false, () => {
          this.onImportEntry();
          this.actionPanelVisible = false;
        });
        this.ActionChip('导出数据', false, () => {
          this.onExportVault();
          this.actionPanelVisible = false;
        });
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(UI_SURFACE)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(18);
  }

  @Builder
  private ActionChip(label: string, primary: boolean, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .fontColor(primary ? '#FFFFFF' : UI_TEXT)
      .height(40)
      .padding({ left: 14, right: 14 })
      .margin({ right: 8, bottom: 8 })
      .textAlign(TextAlign.Center)
      .backgroundColor(primary ? UI_ACCENT : UI_SURFACE_ALT)
      .border({ width: 1, color: primary ? UI_ACCENT : UI_STROKE })
      .borderRadius(12)
      .onClick(action);
  }

  @Builder
  private SmallGhostButton(label: string, action: () => void) {
    Text(label)
      .fontSize(12)
      .fontWeight(FontWeight.Bold)
      .fontColor(UI_TEXT)
      .height(34)
      .padding({ left: 12, right: 12 })
      .textAlign(TextAlign.Center)
      .backgroundColor(UI_SURFACE_ALT)
      .border({ width: 1, color: UI_STROKE })
      .borderRadius(999)
      .onClick(action);
  }

  @Builder
  private StatusSummary() {
    Row() {
      Text(`条目 ${this.entries.length} · 分类 ${this.categories.length} · 同步 ${this.syncStatus}`)
        .fontSize(11)
        .fontColor(UI_MUTED)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1);
    }
    .width('100%')
    .height(40)
    .padding({ left: 12, right: 12 })
    .backgroundColor(UI_SURFACE_ALT)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(14);
  }

  @Builder
  private SettingsPage() {
    Scroll() {
      Column({ space: 12 }) {
        Row() {
          Text('设置')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(UI_TEXT);
          Blank();
          this.SmallGhostButton('返回', () => {
            this.activePanel = 'home';
          });
        }

        this.SecuritySection();
        this.SyncSection();
        this.DeviceSection();
      }
      .width('100%')
      .padding({ bottom: 18 });
    }
    .layoutWeight(1)
    .width('100%');
  }

  @Builder
  private SectionTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .fontColor(UI_ACCENT);
  }

  @Builder
  private SettingToggleRow(label: string, enabled: boolean, action: () => void) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor(UI_TEXT)
        .layoutWeight(1);
      Text(enabled ? '已开启' : '已关闭')
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(enabled ? '#FFFFFF' : UI_TEXT)
        .height(38)
        .padding({ left: 14, right: 14 })
        .textAlign(TextAlign.Center)
        .backgroundColor(enabled ? UI_ACCENT : UI_SURFACE_ALT)
        .border({ width: 1, color: enabled ? UI_ACCENT : UI_STROKE })
        .borderRadius(12)
        .onClick(action);
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 });
  }

  @Builder
  private ChoiceChip(label: string, selected: boolean, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .fontColor(selected ? '#FFFFFF' : UI_TEXT)
      .height(38)
      .padding({ left: 14, right: 14 })
      .margin({ right: 8, bottom: 8 })
      .textAlign(TextAlign.Center)
      .backgroundColor(selected ? UI_ACCENT : UI_SURFACE_ALT)
      .border({ width: 1, color: selected ? UI_ACCENT : UI_STROKE })
      .borderRadius(12)
      .onClick(action);
  }

  @Builder
  private EntryTypeChip(label: string, type: DraftType) {
    Text(label)
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.draftType === type ? '#FFFFFF' : UI_TEXT)
      .height(38)
      .padding({ left: 14, right: 14 })
      .margin({ right: 8, bottom: 8 })
      .textAlign(TextAlign.Center)
      .backgroundColor(this.draftType === type ? UI_ACCENT : UI_SURFACE_ALT)
      .border({ width: 1, color: this.draftType === type ? UI_ACCENT : UI_STROKE })
      .borderRadius(12)
      .onClick(() => {
        if (this.editingEntryId.length === 0) {
          this.draftType = type;
        }
      });
  }

  @Builder
  private SecuritySection() {
    Column({ space: 10 }) {
      this.SectionTitle('安全');
      this.SettingToggleRow('解锁时要求动态验证码', this.securityRequireTotp, () => {
        this.securityRequireTotp = !this.securityRequireTotp;
      });

      TextInput({ placeholder: 'TOTP Shared Secret', text: $$this.securityTotpSecret })
        .type(InputType.Password)
        .width('100%')
        .height(48)
        .backgroundColor(UI_SURFACE_ALT)
        .border({ width: 1, color: UI_STROKE })
        .borderRadius(12)
        .padding({ left: 14, right: 14 });

      this.SettingToggleRow('启用生物识别解锁', this.biometricUnlockRequested, () => {
        if (!this.biometricUnlockAvailable && !this.biometricUnlockRequested) {
          this.toast('此设备没有可用的强生物识别硬件或尚未录入');
          return;
        }
        this.biometricUnlockRequested = !this.biometricUnlockRequested;
        if (!this.biometricUnlockRequested) {
          this.securityBiometricMasterPassword = '';
        }
      });

      if (!this.biometricUnlockAvailable) {
        Text('此设备没有可用的强生物识别硬件或尚未录入。')
          .fontSize(12)
          .fontColor(UI_DANGER);
      }
      if (this.biometricUnlockRequested && !this.biometricUnlockEnabled) {
        TextInput({ placeholder: '输入主密码以启用生物识别', text: $$this.securityBiometricMasterPassword })
          .type(InputType.Password)
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
      }

      Text('闲置自动锁定')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(UI_MUTED);
      TextInput({ placeholder: '分钟，0 为关闭', text: $$this.securityIdleAutoLockMinutes })
        .type(InputType.Number)
        .width('100%')
        .height(48)
        .backgroundColor(UI_SURFACE_ALT)
        .border({ width: 1, color: UI_STROKE })
        .borderRadius(12)
        .padding({ left: 14, right: 14 });
      Text('输入 0 表示关闭；取值范围 0-1440。')
        .fontSize(12)
        .fontColor(UI_MUTED);

      Text(this.securityRequireTotp ? '解锁时将强制校验动态验证码。' : '当前未启用2FA。')
        .fontSize(12)
        .fontColor(UI_MUTED);

      this.PrimaryTextButton('保存安全设置', () => {
        this.onSaveSecuritySettings();
      });
    }
    .width('100%')
    .padding(16)
    .backgroundColor(UI_SURFACE)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(18);
  }

  @Builder
  private SyncSection() {
    Column({ space: 10 }) {
      Row() {
        this.SectionTitle('同步');
        Blank();
        Text(`修订 ${this.syncRevision}`)
          .fontSize(12)
          .fontColor(UI_MUTED);
      }

      Text('提供商')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(UI_MUTED);
      Flex({ wrap: FlexWrap.Wrap }) {
        this.ChoiceChip('关闭', this.syncProviderType === SyncProviderType.NONE, () => {
          this.syncProviderType = SyncProviderType.NONE;
        });
        this.ChoiceChip('WebDAV', this.syncProviderType === SyncProviderType.WEBDAV, () => {
          this.syncProviderType = SyncProviderType.WEBDAV;
        });
        this.ChoiceChip('S3链接', this.syncProviderType === SyncProviderType.S3_PRESIGNED, () => {
          this.syncProviderType = SyncProviderType.S3_PRESIGNED;
        });
        this.ChoiceChip('NAS WebDAV', this.syncProviderType === SyncProviderType.NAS_WEBDAV, () => {
          this.syncProviderType = SyncProviderType.NAS_WEBDAV;
        });
      }

      if (
        this.syncProviderType === SyncProviderType.WEBDAV ||
        this.syncProviderType === SyncProviderType.NAS_WEBDAV
      ) {
        this.SectionTitle('WebDAV 设置');
        TextInput({ placeholder: 'WebDAV URL', text: $$this.syncWebdavUrl })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: '路径，例如 /vault.json', text: $$this.syncWebdavPath })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: '用户名，可选', text: $$this.syncWebdavUsername })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: '密码，可选', text: $$this.syncWebdavPassword })
          .type(InputType.Password)
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
      }

      if (this.syncProviderType === SyncProviderType.S3_PRESIGNED) {
        this.SectionTitle('预签名 URL 设置');
        TextInput({ placeholder: '下载 URL', text: $$this.syncPresignedDownloadUrl })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: '上传 URL', text: $$this.syncPresignedUploadUrl })
          .type(InputType.Password)
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
      }

      this.SettingToggleRow('自动同步', this.syncAutoEnabled, () => {
        this.syncAutoEnabled = !this.syncAutoEnabled;
      });
      Row({ space: 8 }) {
        Text('同步间隔')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_MUTED)
          .width(72);
        TextInput({ placeholder: '数值', text: $$this.syncIntervalValue })
          .type(InputType.Number)
          .layoutWeight(1)
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
      }
      Flex({ wrap: FlexWrap.Wrap }) {
        this.ChoiceChip('秒', this.syncIntervalUnit === SyncIntervalUnit.SECONDS, () => {
          this.syncIntervalUnit = SyncIntervalUnit.SECONDS;
        });
        this.ChoiceChip('分钟', this.syncIntervalUnit === SyncIntervalUnit.MINUTES, () => {
          this.syncIntervalUnit = SyncIntervalUnit.MINUTES;
        });
      }

      this.SettingToggleRow('解锁后同步', this.syncAutoOnUnlock, () => {
        this.syncAutoOnUnlock = !this.syncAutoOnUnlock;
      });
      this.SettingToggleRow('同步主密钥元数据', this.syncMasterKey, () => {
        this.syncMasterKey = !this.syncMasterKey;
      });
      Text('开启后同步包会携带主密钥元数据，便于新设备通过同一主密码解密同步数据。')
        .fontSize(12)
        .fontColor(UI_MUTED);

      Text('冲突策略')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(UI_MUTED);
      Flex({ wrap: FlexWrap.Wrap }) {
        this.ChoiceChip('远端优先', this.syncConflictStrategy === ConflictStrategy.REMOTE_WINS, () => {
          this.syncConflictStrategy = ConflictStrategy.REMOTE_WINS;
        });
        this.ChoiceChip('本地优先', this.syncConflictStrategy === ConflictStrategy.LOCAL_WINS, () => {
          this.syncConflictStrategy = ConflictStrategy.LOCAL_WINS;
        });
        this.ChoiceChip('保留冲突', this.syncConflictStrategy === ConflictStrategy.KEEP_BOTH, () => {
          this.syncConflictStrategy = ConflictStrategy.KEEP_BOTH;
        });
      }

      Row({ space: 8 }) {
        Column() {
          this.SecondaryTextButton('立即同步', () => {
            if (!this.syncBusy) {
              this.onSyncNow();
            }
          });
        }
        .layoutWeight(1)
        Column() {
          this.PrimaryTextButton('保存同步设置', () => {
            this.onSaveSyncSettings();
          });
        }
        .layoutWeight(1)
      }

      Text(this.syncStatus)
        .fontSize(12)
        .fontColor(UI_MUTED);

      if (this.syncLogs.length > 0) {
        Column({ space: 6 }) {
          ForEach(this.syncLogs, (line: string) => {
            Text(line)
              .fontSize(11)
              .fontColor(UI_MUTED)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
          }, (line: string, index: number) => `${line}-${index}`);
        }
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(UI_SURFACE)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(18);
  }

  @Builder
  private DeviceSection() {
    Column({ space: 6 }) {
      this.SectionTitle('设备');
      Text(`设备 ${this.syncDeviceId.length > 0 ? this.syncDeviceId : '-'}`)
        .fontSize(13)
        .fontColor(UI_MUTED);
      Text(`修订 ${this.syncRevision}`)
        .fontSize(13)
        .fontColor(UI_MUTED);
    }
    .width('100%')
    .padding(16)
    .backgroundColor(UI_SURFACE)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(18);
  }

  @Builder
  private PrimaryTextButton(label: string, action: () => void) {
    Text(label)
      .fontSize(14)
      .fontWeight(FontWeight.Bold)
      .fontColor('#FFFFFF')
      .height(44)
      .width('100%')
      .textAlign(TextAlign.Center)
      .backgroundColor(UI_ACCENT)
      .borderRadius(12)
      .onClick(action);
  }

  @Builder
  private SecondaryTextButton(label: string, action: () => void) {
    Text(label)
      .fontSize(14)
      .fontWeight(FontWeight.Bold)
      .fontColor(UI_TEXT)
      .height(44)
      .width('100%')
      .textAlign(TextAlign.Center)
      .backgroundColor(UI_SURFACE_ALT)
      .border({ width: 1, color: UI_STROKE })
      .borderRadius(12)
      .onClick(action);
  }

  @Builder
  private FilterSection() {
    Column({ space: 8 }) {
      if (this.categories.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          this.FilterPill('全部分类', this.selectedCategory.length === 0, () => {
            this.handleCategoryFilterSelection('');
          });
          ForEach(this.categories, (category: string) => {
            this.FilterPill(category, this.selectedCategory === category, () => {
              this.handleCategoryFilterSelection(category);
            });
          }, (category: string) => category);
        }
      }

      Row({ space: 8 }) {
        TextInput({
          placeholder: '搜索密码库，如 ip:1.2.3.4 name:xxx',
          text: $$this.searchQuery,
          controller: this.searchInputController
        })
          .layoutWeight(1)
          .height(46)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(14)
          .padding({ left: 14, right: 14 });
        Text('?')
          .width(46)
          .height(46)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_MUTED)
          .textAlign(TextAlign.Center)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(14)
          .onClick(() => {
            this.showSearchHelp();
          });
      }
        .width('100%')

      if (this.tags.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          this.FilterPill('全部标签', this.selectedTag.length === 0, () => {
            this.handleTagFilterSelection('');
          });
          ForEach(this.tags, (tag: string) => {
            this.FilterPill(tag, this.selectedTag === tag, () => {
              this.handleTagFilterSelection(tag);
            });
          }, (tag: string) => tag);
        }
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(UI_SURFACE)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(18);
  }

  @Builder
  private NewEntrySection() {
    Column({ space: 10 }) {
      Row() {
        Text(this.editingEntryId.length > 0 ? '编辑条目' : '新建条目')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_TEXT);
        Blank();
        this.SmallGhostButton('关闭', () => {
          this.clearEntryDraft();
          this.entryEditorVisible = false;
        });
      }
      Text('条目类型').fontSize(12).fontWeight(FontWeight.Bold).fontColor(UI_MUTED);

      Flex({ wrap: FlexWrap.Wrap }) {
        this.EntryTypeChip('账号', 'credential');
        this.EntryTypeChip('服务器', 'server');
        this.EntryTypeChip('服务', 'service');
      }

      TextInput({ placeholder: '标题（必填）', text: $$this.draftLabel })
        .width('100%')
        .height(48)
        .backgroundColor(UI_SURFACE_ALT)
        .border({ width: 1, color: UI_STROKE })
        .borderRadius(12)
        .padding({ left: 14, right: 14 });

      this.EntryCategorySelect();
      this.EntryTagMultiSelect();

      if (this.draftType === 'credential') {
        TextInput({ placeholder: '用户名', text: $$this.draftCredentialUsername })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: '密码', text: $$this.draftCredentialPassword })
          .type(InputType.Password)
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
      }

      if (this.draftType === 'server') {
        TextInput({ placeholder: '服务器名称', text: $$this.draftServerName })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: 'IP地址', text: $$this.draftServerIp })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: '端口', text: $$this.draftServerPort })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
      }

      if (this.draftType === 'service') {
        TextInput({ placeholder: '服务名称', text: $$this.draftServiceName })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: '连接地址', text: $$this.draftServiceAddress })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: '端口', text: $$this.draftServicePort })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
      }

      this.CustomFieldsEditor();

      this.PrimaryTextButton(this.editingEntryId.length > 0 ? '保存修改' : '保存条目', () => {
        this.onSaveEntry();
      });
    }
    .width('100%')
    .padding(16)
    .backgroundColor(UI_SURFACE)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(18);
  }

  @Builder
  private TagSection() {
    Column({ space: 10 }) {
      Row() {
        Text('标签管理')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_TEXT);
        Blank();
        this.SmallGhostButton('返回', () => {
          this.activePanel = 'home';
        });
      }

      Row({ space: 8 }) {
        TextInput({ placeholder: '新增标签', text: $$this.tagDraft })
          .layoutWeight(1)
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        Text('添加')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .height(48)
          .padding({ left: 16, right: 16 })
          .textAlign(TextAlign.Center)
          .backgroundColor(UI_ACCENT)
          .borderRadius(12)
          .onClick(() => this.onAddTag());
      }

      if (this.tags.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.tags, (tag: string) => {
            Row({ space: 4 }) {
              Text(tag).fontSize(13);
              Text('删除')
                .fontSize(11)
                .fontWeight(FontWeight.Bold)
                .fontColor(UI_DANGER)
                .height(24)
                .padding({ left: 8, right: 8 })
                .textAlign(TextAlign.Center)
                .backgroundColor(UI_DANGER_SURFACE)
                .borderRadius(999)
                .onClick(() => {
                  this.onDeleteTag(tag);
                });
            }
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .margin({ right: 6, bottom: 6 })
            .backgroundColor(UI_SURFACE_ALT)
            .border({ width: 1, color: UI_STROKE })
            .borderRadius(999)
            .onClick(() => {});
          }, (tag: string) => tag);
        }
      } else {
        Text('暂无标签')
          .fontSize(13)
          .fontColor(UI_MUTED);
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(UI_SURFACE)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(18);
  }

  @Builder
  private CategorySection() {
    Column({ space: 10 }) {
      Row() {
        Text('分类管理')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_TEXT);
        Blank();
        Text('导入')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_ACCENT)
          .margin({ right: 16 })
          .onClick(() => {
            this.onImportCategory();
          });
        this.SmallGhostButton('返回', () => {
          this.activePanel = 'home';
        });
      }

      Row({ space: 8 }) {
        TextInput({ placeholder: '新增分类', text: $$this.categoryDraft })
          .layoutWeight(1)
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        Text('添加')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .height(48)
          .padding({ left: 16, right: 16 })
          .textAlign(TextAlign.Center)
          .backgroundColor(UI_ACCENT)
          .borderRadius(12)
          .onClick(() => this.onAddCategory());
        Text(this.categoryRenameSource.length > 0 ? '保存' : '重命名')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_TEXT)
          .height(48)
          .padding({ left: 14, right: 14 })
          .textAlign(TextAlign.Center)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .onClick(() => this.onRenameCategory());
      }

      if (this.categoryRenameSource.length > 0) {
        Row({ space: 8 }) {
          Text(`当前重命名: ${this.categoryRenameSource}`)
            .fontSize(12)
            .fontColor(UI_MUTED);
          Text('取消')
            .fontSize(12)
            .fontColor(UI_ACCENT)
            .onClick(() => {
              this.categoryRenameSource = '';
              this.categoryDraft = '';
            });
        }
      }

      if (this.categories.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.categories, (category: string) => {
            Row({ space: 4 }) {
              Text(category).fontSize(13);
              Button('导出')
                .fontSize(11)
                .height(22)
                .onClick(() => {
                  this.onExportCategory(category);
                });
              Text('删除')
                .fontSize(11)
                .fontWeight(FontWeight.Bold)
                .fontColor(UI_DANGER)
                .height(24)
                .padding({ left: 8, right: 8 })
                .textAlign(TextAlign.Center)
                .backgroundColor(UI_DANGER_SURFACE)
                .borderRadius(999)
                .onClick(() => {
                  this.onDeleteCategory(category);
                });
            }
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .margin({ right: 6, bottom: 6 })
            .backgroundColor(this.categoryRenameSource === category ? UI_SELECTED : UI_SURFACE_ALT)
            .border({ width: 1, color: this.categoryRenameSource === category ? UI_ACCENT : UI_STROKE })
            .borderRadius(999)
            .onClick(() => {
              this.categoryRenameSource = category;
              this.categoryDraft = category;
            });
          }, (category: string) => category);
        }
      } else {
        Text('暂无分类')
          .fontSize(13)
          .fontColor(UI_MUTED);
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(UI_SURFACE)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(18);
  }

  @Builder
  private EntryListSection() {
    Column({ space: 10 }) {
      Row() {
        Text('条目列表')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_TEXT);
        Blank();
        Text(`共 ${this.filteredEntries().length} 条`)
          .fontSize(12)
          .fontColor(UI_MUTED);
      }

      if (this.hasActiveFilters()) {
        this.ActiveFilterSummary(this.filteredEntries().length);
      }

      if (this.filteredEntries().length === 0) {
        Column({ space: 10 }) {
          Text('暂无条目')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(UI_TEXT);
          Text('点右上角 + 创建第一个条目。')
            .fontSize(13)
            .fontColor(UI_MUTED);
          this.PrimaryTextButton('新建条目', () => {
            this.beginCreateEntry();
          });
        }
        .width('100%')
        .padding({ top: 44, bottom: 44, left: 18, right: 18 })
        .alignItems(HorizontalAlign.Center);
      } else {
        List({ space: 8, scroller: this.entryListScroller }) {
          ForEach(this.filteredEntries(), (entry: VaultEntry) => {
            ListItem() {
              Column({ space: 7 }) {
                Row() {
                  Text(entry.label)
                    .fontSize(16)
                    .fontWeight(FontWeight.Bold)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontColor(this.entryTitleMatched(entry) ? UI_ACCENT : UI_TEXT);
                  Blank();
                  Text(this.typeLabel(entry.type))
                    .fontSize(11)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(UI_ACCENT)
                    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                    .backgroundColor(UI_SELECTED)
                    .borderRadius(999);
                }

                Text(this.entrySummary(entry))
                  .fontSize(13)
                  .fontColor(this.entrySummaryMatched(entry) ? UI_ACCENT : UI_MUTED)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
                Text(`${this.entryCategory(entry) || '未分类'}${entry.tags.length > 0 ? '  ' + entry.tags.map((tag: string) => '#' + tag).join(', ') : ''}`)
                  .fontSize(12)
                  .fontColor(this.entryCategoryMatched(entry) ? UI_ACCENT : UI_MUTED)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });

                if (this.entryMatchLabels(entry).length > 0) {
                  this.EntryMatchPills(entry);
                }

                Row() {
                  Text(new Date(entry.updatedAt).toLocaleString())
                    .fontSize(11)
                    .fontColor(UI_MUTED);
                  Blank();
                  Text('导出')
                    .fontSize(12)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(UI_ACCENT)
                    .margin({ right: 14 })
                    .onClick(() => {
                      this.toggleExportPanel(entry);
                    });
                  Text('编辑')
                    .fontSize(12)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(UI_ACCENT)
                    .margin({ right: 14 })
                    .onClick(() => {
                      this.startEditEntry(entry);
                    });
                  Text('删除')
                    .fontSize(12)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(UI_DANGER)
                    .onClick(() => {
                      this.onDeleteEntry(entry.id);
                    });
                }

                if (this.exportEntryId === entry.id) {
                  this.EntryExportPanel(entry);
                }
              }
              .width('100%')
              .padding(14)
              .backgroundColor(UI_SURFACE_ALT)
              .border({ width: 1, color: UI_STROKE })
              .borderRadius(14);
            }
          }, (entry: VaultEntry) => entry.id);
        }
        .layoutWeight(1)
        .width('100%')
        .onScrollIndex((firstIndex: number) => {
          this.entryListFirstVisibleIndex = firstIndex;
        });
      }
    }
    .layoutWeight(1)
    .width('100%')
    .padding(14)
    .backgroundColor(UI_SURFACE)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(18);
  }

  @Builder
  private EntryTagPills(entry: VaultEntry) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(entry.tags, (tag: string) => {
        Text(tag)
          .fontSize(11)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .margin({ right: 6, bottom: 4 })
          .backgroundColor(this.tagMatched(tag) ? UI_SELECTED : UI_SURFACE_ALT)
          .fontColor(this.tagMatched(tag) ? UI_ACCENT : UI_MUTED)
          .borderRadius(999);
      }, (tag: string, index: number) => `${tag}-${index}`);
    }
  }

  @Builder
  private EntryOverview(entry: VaultEntry) {
    Column({ space: 4 }) {
      Text('概览').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#1F2B2D');
      Text(`标签: ${entry.tags.length > 0 ? entry.tags.join(', ') : '-'}`)
        .fontSize(11)
        .fontColor('#5E6A6C')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
      if (entry.customFields.length > 0) {
        Text(`自定义字段: ${entry.customFields.map((field: CustomField) => field.name).join(', ')}`)
          .fontSize(11)
          .fontColor('#5E6A6C')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor('#F6F8F6')
    .borderRadius(10);
  }

  @Builder
  private EntryExportPanel(entry: VaultEntry) {
    Column({ space: 8 }) {
      Text('选择导出字段').fontSize(12).fontWeight(FontWeight.Bold).fontColor(UI_TEXT);
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.exportFieldOptions(entry), (option: ExportFieldOption) => {
          this.FilterPill(option.label, this.exportSelectedFieldIds.includes(option.id), () => {
            this.toggleExportField(option.id);
          });
        }, (option: ExportFieldOption) => option.id);
      }
      Row({ space: 8 }) {
        Column() {
          this.SecondaryTextButton('导出全部', () => {
            this.onExportEntryAll(entry);
          });
        }
        .layoutWeight(1)
        Column() {
          this.PrimaryTextButton('导出所选', () => {
            if (this.exportSelectedFieldIds.length > 0) {
              this.onExportEntrySelected(entry);
            }
          });
        }
        .layoutWeight(1)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(UI_SURFACE)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(12);
  }

  @Builder
  private EntryMatchPills(entry: VaultEntry) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.entryMatchLabels(entry), (label: string) => {
        Text(label)
          .fontSize(11)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .margin({ right: 6, bottom: 4 })
          .backgroundColor(UI_ACCENT)
          .fontColor('#FFFFFF')
          .borderRadius(999);
      }, (label: string, index: number) => `${label}-${index}`);
    }
  }

  @Builder
  private ActiveFilterSummary(resultCount: number) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.activeFilterLabels(resultCount), (label: string) => {
        Text(label)
          .fontSize(11)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .margin({ right: 6, bottom: 4 })
          .backgroundColor(label.startsWith('结果:') ? UI_SELECTED : UI_SURFACE_ALT)
          .fontColor(label.startsWith('结果:') ? UI_ACCENT : UI_MUTED)
          .border({ width: 1, color: label.startsWith('结果:') ? UI_ACCENT : UI_STROKE })
          .borderRadius(999);
      }, (label: string, index: number) => `${label}-${index}`);
    }
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
      this.biometricFailureCount = 0;
      this.biometricAutoPrompted = false;
      this.password = '';
      this.confirmPassword = '';
      this.unlockTotpCode = '';
      this.refreshData();
      this.refreshSecurityState();
      this.refreshSyncState();
      this.refreshUnlockGuardState();
      this.offerBiometricUnlock(password);
      this.configureAutoSyncTimer();
      this.configureIdleLockTimer();
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
    this.biometricFailureCount = 0;
    this.biometricAutoPrompted = false;
    this.password = '';
    this.confirmPassword = '';
    this.unlockTotpCode = '';
    this.refreshData();
    this.refreshSecurityState();
    this.refreshSyncState();
    this.refreshUnlockGuardState();
    this.offerBiometricUnlock(password);
    this.configureAutoSyncTimer();
    this.configureIdleLockTimer();
    this.schedulePostUnlockRefresh();
  }

  private async onBiometricUnlock(): Promise<void> {
    const store = this.biometricCredentialStore;
    if (store === null || this.biometricBusy || this.biometricFailureCount >= 3) {
      return;
    }
    this.biometricBusy = true;
    try {
      const savedPassword = await store.readPassword();
      const unlocked = await this.controller().unlock(savedPassword, this.unlockTotpCode);
      if (!unlocked) {
        this.biometricFailureCount += 1;
        this.refreshUnlockGuardState();
        this.toast(this.controller().getLastUnlockError());
        return;
      }
      this.unlocked = true;
      this.biometricFailureCount = 0;
      this.biometricAutoPrompted = false;
      this.password = '';
      this.confirmPassword = '';
      this.unlockTotpCode = '';
      this.refreshData();
      this.refreshSecurityState();
      this.refreshSyncState();
      this.refreshUnlockGuardState();
      this.configureAutoSyncTimer();
      this.configureIdleLockTimer();
      this.schedulePostUnlockRefresh();
    } catch (error) {
      this.biometricFailureCount += 1;
      this.toast(`${error}`);
    } finally {
      this.biometricBusy = false;
      if (!this.unlocked && this.biometricFailureCount >= 3) {
        this.toast('生物识别失败 3 次，请输入主密码解锁');
      }
    }
  }

  private async offerBiometricUnlock(password: string): Promise<void> {
    const store = this.biometricCredentialStore;
    if (store === null || this.biometricUnlockEnabled || !this.biometricUnlockAvailable || !this.biometricUnlockRequested) {
      return;
    }
    try {
      await store.savePassword(password);
      await this.refreshBiometricState();
      this.toast('已启用生物识别解锁');
    } catch (error) {
      console.error(`Enable biometric unlock skipped: ${error}`);
    }
  }

  private async onSaveEntry(): Promise<void> {
    const label = this.draftLabel.trim();
    if (label.length === 0) {
      this.toast('标题必填');
      return;
    }

    const tags = [...this.draftSelectedTags];
    const category = this.draftCategory.trim();
    const customFields = this.normalizedDraftCustomFields();

    if (this.draftType === 'credential') {
      const input: CreateCredentialInput = {
        label: label,
        username: this.draftCredentialUsername.trim(),
        password: this.draftCredentialPassword,
        token: '',
        appId: '',
        accessKey: '',
        secretKey: '',
        notes: '',
        tags: tags,
        category: category,
        customFields: customFields,
      };
      if (this.editingEntryId.length > 0) {
        await this.controller().updateCredentialEntry(this.editingEntryId, input);
      } else {
        await this.controller().addCredential(input);
      }
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
        tags: tags,
        category: category,
        customFields: customFields,
      };
      if (this.editingEntryId.length > 0) {
        await this.controller().updateServerEntry(this.editingEntryId, input);
      } else {
        await this.controller().addServer(input);
      }
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
        tags: tags,
        category: category,
        customFields: customFields,
      };
      if (this.editingEntryId.length > 0) {
        await this.controller().updateServiceEntry(this.editingEntryId, input);
      } else {
        await this.controller().addService(input);
      }
    }

    this.clearEntryDraft();
    this.entryEditorVisible = false;
    this.activePanel = 'home';
    this.refreshData();
    this.toast('已保存');
  }

  private async onDeleteEntry(entryId: string): Promise<void> {
    await this.controller().deleteEntry(entryId);
    this.refreshData();
  }

  private async onImportEntry(): Promise<void> {
    try {
      const contents = await this.pickJsonFileContents();
      if (contents.length === 0) {
        return;
      }
      const preview = await this.controller().previewImportEntryData(contents);
      const strategy = await this.confirmImportPreview(preview);
      if (strategy === null) {
        return;
      }
      const result = await this.controller().importEntryDataWithStrategy(contents, strategy);
      this.refreshData();
      this.toast(`已导入 ${result.createdCount} 条，更新 ${result.updatedCount} 条，跳过 ${result.skippedCount} 条`);
    } catch (error) {
      this.toast(`导入失败: ${error}`);
    }
  }

  private async onImportCategory(): Promise<void> {
    try {
      const contents = await this.pickJsonFileContents();
      if (contents.length === 0) {
        return;
      }
      const preview = await this.controller().previewImportCategoryData(contents);
      const strategy = await this.confirmImportPreview(preview);
      if (strategy === null) {
        return;
      }
      const result = await this.controller().importCategoryDataWithStrategy(contents, strategy);
      this.refreshData();
      this.toast(`已导入 ${result.createdCount} 条，更新 ${result.updatedCount} 条，跳过 ${result.skippedCount} 条`);
    } catch (error) {
      this.toast(`导入失败: ${error}`);
    }
  }

  private async onExportVault(): Promise<void> {
    try {
      const data = this.controller().exportSnapshot();
      const filePath = await this.saveJsonExportFile('vault-export', 'vault', data);
      this.toast(`已导出到 ${filePath}`);
    } catch (error) {
      this.toast(`导出失败: ${error}`);
    }
  }

  private async onExportEntryAll(entry: VaultEntry): Promise<void> {
    try {
      const data = this.controller().exportEntryData(entry.id);
      const filePath = await this.saveJsonExportFile('entry-export', entry.label, data);
      this.toast(`条目已导出到 ${filePath}`);
    } catch (error) {
      this.toast(`导出失败: ${error}`);
    }
  }

  private async onExportEntrySelected(entry: VaultEntry): Promise<void> {
    if (this.exportSelectedFieldIds.length === 0) {
      this.toast('请先选择导出字段');
      return;
    }
    try {
      const data = this.controller().exportEntryData(entry.id, this.exportSelectedFieldIds);
      const filePath = await this.saveJsonExportFile('entry-export-selected', entry.label, data);
      this.toast(`条目所选字段已导出到 ${filePath}`);
    } catch (error) {
      this.toast(`导出失败: ${error}`);
    }
  }

  private async onExportCategory(category: string): Promise<void> {
    try {
      const data = this.controller().exportCategoryData(category);
      const filePath = await this.saveJsonExportFile('category-export', category, data);
      this.toast(`分类已导出到 ${filePath}`);
    } catch (error) {
      this.toast(`导出失败: ${error}`);
    }
  }

  private async onAddTag(): Promise<void> {
    if (this.tagDraft.trim().length === 0) {
      return;
    }
    await this.controller().addTag(this.tagDraft);
    this.tagDraft = '';
    this.refreshData();
  }

  private async onAddCategory(): Promise<void> {
    const category = this.categoryDraft.trim();
    if (category.length === 0) {
      return;
    }
    await this.controller().addCategory(category);
    this.categoryDraft = '';
    this.categoryRenameSource = '';
    this.refreshData();
  }

  private async onRenameCategory(): Promise<void> {
    const source = this.categoryRenameSource.trim();
    const target = this.categoryDraft.trim();
    if (source.length === 0) {
      this.toast('请先点选一个分类再重命名');
      return;
    }
    if (target.length === 0) {
      this.toast('请输入新的分类名称');
      return;
    }
    await this.controller().renameCategory(source, target);
    if (this.selectedCategory === source) {
      this.selectedCategory = target;
    }
    if (this.draftCategory.trim() === source) {
      this.draftCategory = target;
    }
    this.categoryRenameSource = '';
    this.categoryDraft = '';
    this.refreshData();
  }

  private async onDeleteTag(tag: string): Promise<void> {
    await this.controller().deleteTag(tag);
    if (this.selectedTag === tag) {
      this.selectedTag = '';
    }
    this.refreshData();
  }

  private async onDeleteCategory(category: string): Promise<void> {
    await this.controller().deleteCategory(category);
    if (this.selectedCategory === category) {
      this.selectedCategory = '';
    }
    if (this.draftCategory.trim() === category) {
      this.draftCategory = '';
    }
    if (this.categoryRenameSource === category) {
      this.categoryRenameSource = '';
    }
    this.refreshData();
  }

  private async onSaveSyncSettings(): Promise<void> {
    try {
      const current = this.controller().getSyncSettings();
      const intervalValue = clampInteger(Number(this.syncIntervalValue) || 0, 1, 1440);
      const updated: SyncSettings = {
        providerType: this.syncProviderType,
        webdavUrl: this.syncWebdavUrl.trim(),
        webdavUsername: this.syncWebdavUsername.trim(),
        webdavPassword: this.syncWebdavPassword,
        webdavPath: this.syncWebdavPath.trim(),
        presignedDownloadUrl: this.syncPresignedDownloadUrl.trim(),
        presignedUploadUrl: this.syncPresignedUploadUrl.trim(),
        autoSyncEnabled: this.syncAutoEnabled,
        autoSyncIntervalMinutes: this.syncIntervalUnit === SyncIntervalUnit.SECONDS
          ? Math.max(Math.ceil(intervalValue / 60), 1)
          : intervalValue,
        autoSyncIntervalValue: intervalValue,
        autoSyncIntervalUnit: this.syncIntervalUnit,
        autoSyncOnUnlock: this.syncAutoOnUnlock,
        conflictStrategy: this.syncConflictStrategy,
        syncMasterKey: this.syncMasterKey,
        deviceId: current.deviceId,
        lastSyncRevision: current.lastSyncRevision,
        lastSyncAt: current.lastSyncAt,
        lastSyncStatus: current.lastSyncStatus,
        lastSyncMessage: current.lastSyncMessage,
        lastRemoteFingerprint: current.lastRemoteFingerprint,
        hasLocalChanges: current.hasLocalChanges,
        logs: current.logs,
      };
      await this.controller().updateSyncSettings(updated);
      this.refreshSyncState();
      this.configureAutoSyncTimer();
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
      this.refreshData(true);
      this.refreshSyncState();
      this.syncBusy = false;
    }
  }

  private configureAutoSyncTimer(): void {
    this.stopAutoSyncTimer();
    if (!this.unlocked || !this.syncAutoEnabled || this.syncProviderType === SyncProviderType.NONE) {
      return;
    }
    this.autoSyncTimerId = setInterval(() => {
      this.runScheduledAutoSync();
    }, 1000);
  }

  private stopAutoSyncTimer(): void {
    if (this.autoSyncTimerId < 0) {
      return;
    }
    clearInterval(this.autoSyncTimerId);
    this.autoSyncTimerId = -1;
  }

  private async runScheduledAutoSync(): Promise<void> {
    if (!this.unlocked || this.syncBusy) {
      return;
    }
    if (!this.controller().shouldRunAutoSync()) {
      return;
    }
    this.syncBusy = true;
    try {
      await this.controller().runAutoSyncIfNeeded();
    } catch (error) {
      console.error(`Scheduled auto sync failed: ${error}`);
    } finally {
      this.refreshData(true);
      this.refreshSyncState();
      this.syncBusy = false;
      this.configureAutoSyncTimer();
    }
  }

  private async onSaveSecuritySettings(): Promise<void> {
    try {
      const secret = this.securityTotpSecret.trim().replace(/\s+/g, '').toUpperCase();
      if (this.securityRequireTotp && secret.length === 0) {
        this.toast('开启2FA时必须填写 TOTP Secret');
        return;
      }
      const store = this.biometricCredentialStore;
      const requestedBiometric = this.biometricUnlockRequested === true;
      if (requestedBiometric) {
        if (store === null || !this.biometricUnlockAvailable) {
          this.toast('此设备没有可用的强生物识别硬件或尚未录入');
          return;
        }
        if (!this.biometricUnlockEnabled) {
          const password = this.securityBiometricMasterPassword.trim();
          if (password.length === 0) {
            this.toast('启用生物识别前请输入主密码');
            return;
          }
          const verified = await this.controller().verifyMasterPassword(password);
          if (!verified) {
            this.toast('主密码错误，无法启用生物识别');
            return;
          }
          await store.savePassword(password);
          this.securityBiometricMasterPassword = '';
        }
      }
      const settings: SecuritySettings = {
        requireTotp: this.securityRequireTotp,
        totpSecret: this.securityRequireTotp ? secret : '',
        biometricUnlockEnabled: requestedBiometric,
        idleAutoLockMinutes: clampInteger(Number(this.securityIdleAutoLockMinutes) || 0, 0, 1440),
      };
      await this.controller().updateSecuritySettings(settings);
      if (!requestedBiometric) {
        if (store !== null) {
          await store.clear();
        }
        this.biometricFailureCount = 0;
        this.securityBiometricMasterPassword = '';
      }
      this.refreshSecurityState();
      await this.refreshBiometricState();
      this.configureIdleLockTimer();
      this.toast('安全设置已保存');
    } catch (error) {
      this.toast(`保存失败: ${error}`);
    }
  }

  private refreshData(preserveEntryScroll: boolean = false): void {
    const anchorEntryId = preserveEntryScroll ? this.currentEntryListAnchorId() : '';
    this.entries = this.controller().getEntries();
    this.tags = this.controller().getTags();
    this.categories = this.controller().getCategories();
    if (preserveEntryScroll) {
      setTimeout(() => {
        this.restoreEntryListAnchor(anchorEntryId);
      }, 0);
    }
  }

  private currentEntryListAnchorId(): string {
    const visible = this.filteredEntries();
    if (visible.length === 0) {
      return '';
    }
    const index = Math.min(Math.max(this.entryListFirstVisibleIndex, 0), visible.length - 1);
    return visible[index].id;
  }

  private restoreEntryListAnchor(anchorEntryId: string): void {
    if (this.activePanel !== 'home' || this.entryEditorVisible) {
      return;
    }
    const visible = this.filteredEntries();
    if (visible.length === 0) {
      this.entryListFirstVisibleIndex = 0;
      return;
    }
    let targetIndex = anchorEntryId.length > 0
      ? visible.findIndex((entry: VaultEntry) => entry.id === anchorEntryId)
      : -1;
    if (targetIndex < 0) {
      targetIndex = Math.min(Math.max(this.entryListFirstVisibleIndex, 0), visible.length - 1);
    }
    this.entryListFirstVisibleIndex = targetIndex;
    this.entryListScroller.scrollToIndex(targetIndex);
  }

  @Builder
  private EntryCategorySelect() {
    Column({ space: 6 }) {
      Text('分类').fontSize(12).fontWeight(FontWeight.Bold).fontColor(UI_MUTED);
      if (this.draftCategory.length > 0) {
        Row({ space: 6 }) {
          Text(`已选: ${this.draftCategory}`)
            .fontSize(12)
            .fontColor(UI_ACCENT)
            .layoutWeight(1);
          Text('清除')
            .fontSize(12)
            .fontColor(UI_MUTED)
            .onClick(() => {
              this.draftCategory = '';
              this.draftCategorySearch = '';
            });
        }
      }
      Row({ space: 8 }) {
        TextInput({ placeholder: '搜索分类', text: $$this.draftCategorySearch })
          .layoutWeight(1)
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        Text('+')
          .width(48)
          .height(48)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.canCreateDraftCategory() ? '#FFFFFF' : UI_MUTED)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.canCreateDraftCategory() ? UI_ACCENT : UI_SURFACE_ALT)
          .border({ width: 1, color: this.canCreateDraftCategory() ? UI_ACCENT : UI_STROKE })
          .borderRadius(12)
          .onClick(() => {
            if (this.canCreateDraftCategory()) {
              this.createDraftCategoryFromSearch();
            }
          });
      }
      if (this.filteredDraftCategories().length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.filteredDraftCategories(), (category: string) => {
            this.FilterPill(category, this.draftCategory === category, () => {
              this.selectDraftCategory(category);
            });
          }, (category: string) => category);
        }
      } else {
        Text('没有匹配分类，可点 + 创建')
          .fontSize(12)
          .fontColor(UI_MUTED);
      }
    }
  }

  @Builder
  private EntryTagMultiSelect() {
    Column({ space: 6 }) {
      Text('标签').fontSize(12).fontWeight(FontWeight.Bold).fontColor(UI_MUTED);
      if (this.draftSelectedTags.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.draftSelectedTags, (tag: string) => {
            this.FilterPill(`✓ ${tag}`, true, () => {
              this.draftTagSearch = tag;
            });
          }, (tag: string) => tag);
        }
      } else {
        Text('未选择标签')
          .fontSize(12)
          .fontColor(UI_MUTED);
      }
      Row({ space: 8 }) {
        TextInput({ placeholder: '搜索标签', text: $$this.draftTagSearch })
          .layoutWeight(1)
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        Text('+')
          .width(48)
          .height(48)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.canCreateDraftTag() ? '#FFFFFF' : UI_MUTED)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.canCreateDraftTag() ? UI_ACCENT : UI_SURFACE_ALT)
          .border({ width: 1, color: this.canCreateDraftTag() ? UI_ACCENT : UI_STROKE })
          .borderRadius(12)
          .onClick(() => {
            if (this.canCreateDraftTag()) {
              this.createDraftTagFromSearch();
            }
          });
      }
      if (this.filteredDraftTags().length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.filteredDraftTags(), (tag: string) => {
            this.FilterPill(
              this.draftSelectedTags.includes(tag) ? `✓ ${tag}` : tag,
              this.draftSelectedTags.includes(tag),
              () => {
                this.toggleDraftTag(tag);
              },
            );
          }, (tag: string) => tag);
        }
      } else {
        Text('没有匹配标签，可点 + 创建')
          .fontSize(12)
          .fontColor(UI_MUTED);
      }
    }
  }

  @Builder
  private CustomFieldsEditor() {
    Column({ space: 6 }) {
      Row() {
        Text('自定义字段').fontSize(12).fontWeight(FontWeight.Bold).fontColor(UI_MUTED);
        Blank();
        Text('+')
          .width(42)
          .height(34)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_ACCENT)
          .textAlign(TextAlign.Center)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(10)
          .onClick(() => {
            this.addDraftCustomField();
          });
      }
      if (this.draftCustomFields.length === 0) {
        Text('未添加自定义字段')
          .fontSize(12)
          .fontColor(UI_MUTED);
      }
      ForEach(this.draftCustomFields, (field: CustomField) => {
        Row({ space: 8 }) {
          TextInput({ placeholder: '字段名称', text: field.name })
            .layoutWeight(1)
            .height(48)
            .backgroundColor(UI_SURFACE_ALT)
            .border({ width: 1, color: UI_STROKE })
            .borderRadius(12)
            .padding({ left: 14, right: 14 })
            .onChange((value: string) => {
              this.updateDraftCustomFieldName(field.id, value);
            });
          TextInput({ placeholder: '字段值', text: field.value })
            .layoutWeight(1)
            .height(48)
            .backgroundColor(UI_SURFACE_ALT)
            .border({ width: 1, color: UI_STROKE })
            .borderRadius(12)
            .padding({ left: 14, right: 14 })
            .onChange((value: string) => {
              this.updateDraftCustomFieldValue(field.id, value);
            });
          Text('删除')
            .height(36)
            .padding({ left: 10, right: 10 })
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(UI_DANGER)
            .textAlign(TextAlign.Center)
            .backgroundColor(UI_DANGER_SURFACE)
            .borderRadius(999)
            .onClick(() => {
              this.removeDraftCustomField(field.id);
            });
        }
      }, (field: CustomField) => field.id);
    }
  }

  private async saveJsonExportFile(prefix: string, name: string, contents: string): Promise<string> {
    if (this.hostContext === null) {
      throw new Error('Host context unavailable');
    }
    const documentPicker = new picker.DocumentViewPicker(this.hostContext);
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [`${prefix}-${this.sanitizeFilename(name)}-${this.exportTimestamp()}.json`];
    options.fileSuffixChoices = ['JSON|json'];
    const uris = await documentPicker.save(options);
    if (uris.length === 0) {
      throw new Error('未选择保存位置');
    }
    const targetUri = uris[0];
    let file: fs.File | null = null;
    try {
      file = fs.openSync(
        targetUri,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE,
      );
      fs.writeSync(file.fd, contents, {
        encoding: 'utf-8',
      });
      return targetUri;
    } catch (error) {
      throw new Error(`写入导出文件失败: ${error}`);
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (closeError) {
          console.error(`close export file failed: ${closeError}`);
        }
      }
    }
  }

  private async pickJsonFileContents(): Promise<string> {
    if (this.hostContext === null) {
      throw new Error('Host context unavailable');
    }
    const documentPicker = new picker.DocumentViewPicker(this.hostContext);
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['json'];
    const uris = await documentPicker.select(options);
    if (uris.length === 0) {
      return '';
    }
    try {
      return fs.readTextSync(uris[0]);
    } catch (error) {
      throw new Error(`读取导入文件失败: ${error}`);
    }
  }

  private async confirmImportPreview(
    preview: ImportPreviewRecord,
  ): Promise<ImportConflictStrategy | null> {
    const lines = preview.items
      .slice(0, 5)
      .map(
        (item) =>
          `${this.typeLabel(item.type)} ${item.label} · ${
            item.category.length > 0 ? item.category : '未分类'
          } · ${this.importDispositionLabel(item.disposition)}`,
      )
      .join('\n');
    const message = `共 ${preview.totalCount} 条：新增 ${preview.createCount}，重复 ${preview.exactDuplicateCount}，冲突 ${preview.conflictCount}` +
      (lines.length > 0 ? `\n\n${lines}` : '');
    try {
      const prompt = this.uiPromptAction();
      const confirmation = await prompt.showDialog({
        title: '导入预览',
        message,
        buttons: [
          { text: '取消', color: '#666666' },
          { text: '继续', color: UI_ACCENT, primary: true },
        ],
      });
      if (confirmation.index !== 1) {
        return null;
      }
      if (preview.exactDuplicateCount === 0 && preview.conflictCount === 0) {
        return ImportConflictStrategy.KEEP_COPY;
      }
      const action = await prompt.showActionMenu({
        title: '冲突处理策略',
        buttons: [
          { text: '保留副本', color: UI_ACCENT },
          { text: '覆盖现有', color: UI_ACCENT },
          { text: '跳过冲突', color: '#666666' },
        ],
      });
      if (action.index === 0) {
        return ImportConflictStrategy.KEEP_COPY;
      }
      if (action.index === 1) {
        return ImportConflictStrategy.OVERWRITE;
      }
      if (action.index === 2) {
        return ImportConflictStrategy.SKIP;
      }
    } catch (error) {
      throw new Error(`打开导入确认失败: ${error}`);
    }
    return null;
  }

  private importDispositionLabel(disposition: string): string {
    if (disposition === 'create') {
      return '新增';
    }
    if (disposition === 'exactDuplicate') {
      return '重复';
    }
    return '冲突';
  }

  private sanitizeFilename(input: string): string {
    const trimmed = input.trim();
    if (trimmed.length === 0) {
      return 'vault';
    }
    const safe = trimmed.replace(/[^0-9a-zA-Z\u4e00-\u9fa5._-]+/g, '_');
    return safe.length > 0 ? safe : 'vault';
  }

  private exportTimestamp(): string {
    return new Date().toISOString().replace(/[:]/g, '-');
  }

  private uiPromptAction() {
    return this.getUIContext().getPromptAction();
  }

  private async showSearchHelp(): Promise<void> {
    try {
      const prompt = this.uiPromptAction();
      await prompt.showDialog({
        title: '搜索用法',
        message: '普通关键词按当前分类匹配；tag:xxx 或 #xxx 可跨分类全局匹配标签；多个词按 AND 过滤。\n\n字段前缀：name:xxx 名称/标题，category:xxx 分类，tag:xxx 标签，app:xxx 应用ID，server:xxx 服务器，ip:xxx 服务器IP或服务地址。也支持自定义字段 key:value，如 owner:sre。\n\n示例：tag:prod ip:10.0，name:aws owner:sre。',
        buttons: [
          { text: '知道了', color: UI_ACCENT, primary: true },
        ],
      });
    } catch (error) {
      this.toast(`搜索用法打开失败: ${error}`);
    }
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
    this.syncAutoEnabled = settings.autoSyncEnabled;
    this.syncAutoOnUnlock = settings.autoSyncOnUnlock;
    this.syncMasterKey = settings.syncMasterKey;
    this.syncIntervalValue = String(settings.autoSyncIntervalValue ?? settings.autoSyncIntervalMinutes ?? 30);
    this.syncIntervalUnit = settings.autoSyncIntervalUnit ?? SyncIntervalUnit.MINUTES;
    this.syncDeviceId = settings.deviceId;
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
    this.biometricUnlockRequested = settings.biometricUnlockEnabled === true;
    this.securityIdleAutoLockMinutes = String(settings.idleAutoLockMinutes ?? 0);
    if (this.biometricUnlockEnabled) {
      this.securityBiometricMasterPassword = '';
    }
  }

  private refreshUnlockGuardState(): void {
    const guard = this.controller().getUnlockGuardState();
    this.unlockFailedAttempts = guard.failedAttempts;
    this.unlockRemainingSeconds = this.controller().getLockRemainingSeconds();
  }

  private async refreshBiometricState(): Promise<void> {
    const store = this.biometricCredentialStore;
    if (store === null) {
      this.biometricUnlockAvailable = false;
      this.biometricUnlockEnabled = false;
      return;
    }
    this.biometricUnlockAvailable = await store.canAuthenticate();
    const hasCredential = await store.hasSavedCredential();
    if (!this.unlocked && hasCredential) {
      this.biometricUnlockRequested = true;
    }
    this.biometricUnlockEnabled = this.biometricUnlockRequested && hasCredential;
  }

  private parseTags(raw: string): string[] {
    const items = raw.split(',').map((entry: string) => entry.trim()).filter((entry: string) => entry.length > 0);
    const unique = new Set<string>();
    items.forEach((item: string) => unique.add(item));
    const normalized: string[] = [];
    unique.forEach((item: string) => normalized.push(item));
    return normalized;
  }

  private filteredDraftCategories(): string[] {
    const query = this.draftCategorySearch.trim().toLowerCase();
    if (query.length === 0) {
      return this.categories.slice(0, 12);
    }
    return this.categories
      .filter((category: string) => category.toLowerCase().includes(query))
      .slice(0, 12);
  }

  private canCreateDraftCategory(): boolean {
    const value = this.draftCategorySearch.trim();
    return value.length > 0 &&
      !this.categories.some((category: string) => category.toLowerCase() === value.toLowerCase());
  }

  private async createDraftCategoryFromSearch(): Promise<void> {
    if (!this.canCreateDraftCategory()) {
      return;
    }
    const category = this.draftCategorySearch.trim();
    await this.controller().addCategory(category);
    this.refreshData();
    this.selectDraftCategory(category);
  }

  private selectDraftCategory(category: string): void {
    this.draftCategory = category;
    this.draftCategorySearch = '';
  }

  private filteredDraftTags(): string[] {
    const query = this.draftTagSearch.trim().toLowerCase();
    if (query.length === 0) {
      return this.tags.slice(0, 12);
    }
    return this.tags
      .filter((tag: string) => tag.toLowerCase().includes(query))
      .slice(0, 12);
  }

  private canCreateDraftTag(): boolean {
    const value = this.draftTagSearch.trim();
    return value.length > 0 &&
      !this.tags.some((tag: string) => tag.toLowerCase() === value.toLowerCase()) &&
      !this.draftSelectedTags.some((tag: string) => tag.toLowerCase() === value.toLowerCase());
  }

  private async createDraftTagFromSearch(): Promise<void> {
    if (!this.canCreateDraftTag()) {
      return;
    }
    const tag = this.draftTagSearch.trim();
    await this.controller().addTag(tag);
    this.refreshData();
    this.draftSelectedTags = [...this.draftSelectedTags, tag].sort((left: string, right: string) => left.localeCompare(right));
    this.draftTagSearch = '';
  }

  private toggleDraftTag(tag: string): void {
    if (this.draftSelectedTags.includes(tag)) {
      this.draftSelectedTags = this.draftSelectedTags.filter((entry: string) => entry !== tag);
      return;
    }
    this.draftSelectedTags = [...this.draftSelectedTags, tag].sort((left: string, right: string) => left.localeCompare(right));
  }

  private clearEntryDraft(): void {
    this.draftLabel = '';
    this.draftCategory = '';
    this.draftCategorySearch = '';
    this.draftTagSearch = '';
    this.draftSelectedTags = [];
    this.draftCustomFields = [];
    this.editingEntryId = '';
    this.draftCredentialUsername = '';
    this.draftCredentialPassword = '';
    this.draftServerName = '';
    this.draftServerIp = '';
    this.draftServerPort = '';
    this.draftServiceName = '';
    this.draftServiceAddress = '';
    this.draftServicePort = '';
  }

  private beginCreateEntry(): void {
    this.clearEntryDraft();
    this.activePanel = 'home';
    this.entryEditorVisible = true;
    this.actionPanelVisible = false;
  }

  private startEditEntry(entry: VaultEntry): void {
    this.clearEntryDraft();
    this.activePanel = 'home';
    this.entryEditorVisible = true;
    this.actionPanelVisible = false;
    this.editingEntryId = entry.id;
    this.exportEntryId = '';
    this.draftLabel = entry.label;
    this.draftCategory = this.entryCategory(entry);
    this.draftSelectedTags = [...entry.tags];
    this.draftCustomFields = this.copyCustomFields(entry.customFields);

    if (entry.type === VaultEntryType.CREDENTIAL) {
      const payload = entry.payload as CredentialPayload;
      this.draftType = 'credential';
      this.draftCredentialUsername = payload.username ?? '';
      this.draftCredentialPassword = payload.password ?? '';
      return;
    }
    if (entry.type === VaultEntryType.SERVER) {
      const payload = entry.payload as ServerPayload;
      this.draftType = 'server';
      this.draftServerName = payload.name ?? '';
      this.draftServerIp = payload.ipAddress ?? '';
      this.draftServerPort = payload.port ?? '';
      return;
    }
    const payload = entry.payload as ServicePayload;
    this.draftType = 'service';
    this.draftServiceName = payload.name ?? '';
    this.draftServiceAddress = payload.connectionAddress ?? '';
    this.draftServicePort = payload.connectionPort ?? '';
  }

  private addDraftCustomField(): void {
    const field: CustomField = {
      id: this.nextUiId(),
      name: '',
      value: '',
    };
    this.draftCustomFields = [...this.draftCustomFields, field];
  }

  private updateDraftCustomFieldName(id: string, value: string): void {
    this.draftCustomFields = this.draftCustomFields.map((field: CustomField) => {
      if (field.id !== id) {
        return field;
      }
      return {
        id: field.id,
        name: value,
        value: field.value,
      };
    });
  }

  private updateDraftCustomFieldValue(id: string, value: string): void {
    this.draftCustomFields = this.draftCustomFields.map((field: CustomField) => {
      if (field.id !== id) {
        return field;
      }
      return {
        id: field.id,
        name: field.name,
        value: value,
      };
    });
  }

  private removeDraftCustomField(id: string): void {
    this.draftCustomFields = this.draftCustomFields.filter((field: CustomField) => field.id !== id);
  }

  private normalizedDraftCustomFields(): CustomField[] {
    return this.draftCustomFields
      .map((field: CustomField) => {
        const normalized: CustomField = {
          id: field.id.length > 0 ? field.id : this.nextUiId(),
          name: field.name.trim(),
          value: field.value,
        };
        return normalized;
      })
      .filter((field: CustomField) => field.name.length > 0 || field.value.trim().length > 0);
  }

  private copyCustomFields(fields: CustomField[]): CustomField[] {
    return fields.map((field: CustomField) => {
      const copy: CustomField = {
        id: field.id.length > 0 ? field.id : this.nextUiId(),
        name: field.name,
        value: field.value,
      };
      return copy;
    });
  }

  private toggleExportPanel(entry: VaultEntry): void {
    if (this.exportEntryId === entry.id) {
      this.exportEntryId = '';
      this.exportSelectedFieldIds = [];
      return;
    }
    this.exportEntryId = entry.id;
    this.exportSelectedFieldIds = [];
  }

  private toggleExportField(fieldId: string): void {
    if (this.exportSelectedFieldIds.includes(fieldId)) {
      this.exportSelectedFieldIds = this.exportSelectedFieldIds.filter((id: string) => id !== fieldId);
      return;
    }
    this.exportSelectedFieldIds = [...this.exportSelectedFieldIds, fieldId];
  }

  private exportFieldOptions(entry: VaultEntry): ExportFieldOption[] {
    const options: ExportFieldOption[] = [
      { id: 'label', label: '标题' },
      { id: 'category', label: '分类' },
      { id: 'tags', label: '标签' },
      { id: 'createdAt', label: '创建时间' },
      { id: 'updatedAt', label: '更新时间' },
    ];
    this.payloadExportFieldOptions(entry).forEach((option: ExportFieldOption) => options.push(option));
    entry.customFields.forEach((field: CustomField) => {
      options.push({
        id: `custom.${field.id}`,
        label: field.name.length > 0 ? field.name : '自定义字段',
      });
    });
    return options;
  }

  private payloadExportFieldOptions(entry: VaultEntry): ExportFieldOption[] {
    if (entry.type === VaultEntryType.CREDENTIAL) {
      return [
        { id: 'payload.username', label: '用户名' },
        { id: 'payload.password', label: '密码' },
        { id: 'payload.token', label: 'Token' },
        { id: 'payload.appId', label: 'App ID' },
        { id: 'payload.accessKey', label: 'Access Key' },
        { id: 'payload.secretKey', label: 'Secret Key' },
        { id: 'payload.notes', label: '备注' },
      ];
    }
    if (entry.type === VaultEntryType.SERVER) {
      return [
        { id: 'payload.name', label: '服务器名称' },
        { id: 'payload.ipAddress', label: 'IP地址' },
        { id: 'payload.port', label: '端口' },
        { id: 'payload.username', label: '用户名' },
        { id: 'payload.password', label: '密码' },
        { id: 'payload.basicConfig', label: '基础配置' },
        { id: 'payload.operatingSystem', label: '操作系统' },
        { id: 'payload.location', label: '位置' },
        { id: 'payload.notes', label: '备注' },
      ];
    }
    return [
      { id: 'payload.name', label: '服务名称' },
      { id: 'payload.connectionAddress', label: '连接地址' },
      { id: 'payload.connectionPort', label: '端口' },
      { id: 'payload.accountId', label: '账号ID' },
      { id: 'payload.serverIds', label: '服务器ID' },
      { id: 'payload.accounts', label: '账号列表' },
      { id: 'payload.notes', label: '备注' },
    ];
  }

  private lockVault(): void {
    this.controller().lock();
    this.unlocked = false;
    this.password = '';
    this.confirmPassword = '';
    this.unlockTotpCode = '';
    this.syncBusy = false;
    this.syncStatus = '未同步';
    this.syncLogs = [];
    this.biometricAutoPrompted = false;
    this.activePanel = 'home';
    this.actionPanelVisible = false;
    this.entryEditorVisible = false;
    this.clearEntryDraft();
    this.refreshUnlockGuardState();
    this.stopAutoSyncTimer();
    this.stopIdleLockTimer();
    this.refreshBiometricState().then(() => {
      this.scheduleBiometricUnlockPrompt();
    });
  }

  private recordUserActivity(): void {
    if (!this.unlocked) {
      return;
    }
    this.lastActivityAt = Date.now();
  }

  private configureIdleLockTimer(): void {
    this.stopIdleLockTimer();
    if (!this.unlocked) {
      return;
    }
    const minutes = Math.max(Math.floor(Number(this.securityIdleAutoLockMinutes) || 0), 0);
    if (minutes <= 0) {
      return;
    }
    this.lastActivityAt = Date.now();
    this.idleLockTimerId = setInterval(() => {
      if (!this.unlocked) {
        this.stopIdleLockTimer();
        return;
      }
      if (Date.now() - this.lastActivityAt >= minutes * 60 * 1000) {
        this.lockVault();
        this.toast('闲置超时，已自动锁定');
      }
    }, 1000);
  }

  private stopIdleLockTimer(): void {
    if (this.idleLockTimerId < 0) {
      return;
    }
    clearInterval(this.idleLockTimerId);
    this.idleLockTimerId = -1;
  }

  private scheduleBiometricUnlockPrompt(): void {
    if (
      !this.ready ||
      !this.hasMasterKey ||
      this.unlocked ||
      !this.biometricUnlockEnabled ||
      !this.biometricUnlockAvailable ||
      this.biometricFailureCount >= 3 ||
      this.biometricAutoPrompted
    ) {
      return;
    }
    this.biometricAutoPrompted = true;
    setTimeout(() => {
      if (!this.unlocked && this.biometricFailureCount < 3) {
        this.onBiometricUnlock();
      }
    }, 300);
  }

  private nextUiId(): string {
    const ts = Date.now().toString(36);
    const rand = Math.floor(Math.random() * 1000000).toString(36);
    return `${ts}-${rand}`;
  }

  private remainingUnlockAttempts(): number {
    const left = MAX_UNLOCK_ATTEMPTS - this.unlockFailedAttempts;
    return left > 0 ? left : 0;
  }

  private hasActiveFilters(): boolean {
    return this.searchQuery.trim().length > 0 ||
      this.selectedCategory.trim().length > 0 ||
      this.selectedTag.trim().length > 0;
  }

  private activeFilterLabels(resultCount: number): string[] {
    const labels: string[] = [];
    if (this.selectedCategory.trim().length > 0) {
      labels.push(`分类: ${this.selectedCategory.trim()}`);
    }
    if (this.selectedTag.trim().length > 0) {
      labels.push(`标签: ${this.selectedTag.trim()}`);
    }
    if (this.searchQuery.trim().length > 0) {
      labels.push(this.usesGlobalTagSearch(this.parseSearchTerms(this.searchQuery))
        ? '搜索: 全局标签'
        : '搜索: 当前分类');
    }
    labels.push(`结果: ${resultCount}`);
    return labels;
  }

  private filteredEntries(): VaultEntry[] {
    const terms = this.parseSearchTerms(this.searchQuery);
    const globalTagSearch = this.usesGlobalTagSearch(terms);
    const selectedCategory = this.selectedCategory.trim().toLowerCase();
    const selectedTag = this.selectedTag.trim().toLowerCase();
    return this.entries.filter((entry: VaultEntry) => {
      if (selectedCategory.length > 0 &&
          this.entryCategory(entry).toLowerCase() !== selectedCategory) {
        return false;
      }
      if (selectedTag.length > 0) {
        const matched = entry.tags.some((entryTag: string) => entryTag.toLowerCase() === selectedTag);
        if (!matched) {
          return false;
        }
      }
      if (terms.length === 0) {
        return true;
      }
      return this.entryMatchesSearch(entry, terms);
    });
  }

  private parseSearchTerms(raw: string): SearchTerm[] {
    const trimmed = raw.trim();
    if (trimmed.length === 0) {
      return [];
    }
    const parts = trimmed.split(/[\s,]+/);
    const terms: SearchTerm[] = [];
    parts.forEach((part: string) => {
      if (part.length === 0) {
        return;
      }
      if (part.startsWith('#') && part.length > 1) {
        terms.push({ field: 'tag', value: part.substring(1).toLowerCase() });
        return;
      }
      const splitIndex = part.indexOf(':');
      if (splitIndex > 0 && splitIndex < part.length - 1) {
        const rawPrefix = part.substring(0, splitIndex).trim().toLowerCase();
        if (rawPrefix === 'http' || rawPrefix === 'https') {
          terms.push({ field: 'any', value: part.toLowerCase() });
          return;
        }
        const prefix = this.normalizeSearchField(rawPrefix);
        const value = part.substring(splitIndex + 1).trim().toLowerCase();
        if (prefix.length === 0 || value.length === 0) {
          return;
        }
        terms.push({ field: prefix, value: value });
        return;
      }
      terms.push({ field: 'any', value: part.toLowerCase() });
    });
    return terms;
  }

  private normalizeSearchField(raw: string): string {
    const key = raw.toLowerCase().replace(/[^a-z0-9]/g, '');
    if (key === 'title' || key === 'label') {
      return 'label';
    }
    if (key === 'name') {
      return 'name';
    }
    if (key === 'type' || key === 'kind') {
      return 'type';
    }
    if (key === 'category' || key === 'cat') {
      return 'category';
    }
    if (key === 'tag' || key === 'tags') {
      return 'tag';
    }
    if (key === 'user' || key === 'username' || key === 'login') {
      return 'username';
    }
    if (key === 'ip' || key === 'ipaddress') {
      return 'ip';
    }
    if (key === 'address' || key === 'addr' || key === 'host' ||
        key === 'url' || key === 'connection' || key === 'connectionaddress') {
      return 'address';
    }
    if (key === 'app' || key === 'appid' || key === 'application') {
      return 'app';
    }
    if (key === 'account' || key === 'accountid') {
      return 'account';
    }
    if (key === 'server' || key === 'servers' || key === 'serverid' ||
        key === 'serverids' || key === 'srv') {
      return 'server';
    }
    if (key === 'service' || key === 'svc') {
      return 'service';
    }
    if (key === 'note' || key === 'notes') {
      return 'notes';
    }
    if (key === 'password' || key === 'pass' || key === 'pwd') {
      return 'password';
    }
    if (key === 'access' || key === 'accesskey' || key === 'ak') {
      return 'accesskey';
    }
    if (key === 'secret' || key === 'secretkey' || key === 'sk') {
      return 'secret';
    }
    if (key === 'field' || key === 'custom') {
      return 'custom';
    }
    return key;
  }

  private usesGlobalTagSearch(terms: SearchTerm[]): boolean {
    return terms.length > 0 &&
      terms.every((term: SearchTerm) => term.field === 'tag');
  }

  private termValues(fields: string[]): string[] {
    const allow = new Set<string>(fields);
    const values = new Set<string>();
    this.parseSearchTerms(this.searchQuery).forEach((term: SearchTerm) => {
      if (allow.has(term.field) && term.value.trim().length > 0) {
        values.add(term.value.trim());
      }
    });
    return Array.from(values.values());
  }

  private textContainsTerms(text: string, fields: string[]): boolean {
    const lowerText = text.toLowerCase();
    return this.termValues(fields).some((value: string) => lowerText.includes(value));
  }

  private entryTitleMatched(entry: VaultEntry): boolean {
    return this.textContainsTerms(entry.label, ['any', 'label', 'name', 'service', 'server', 'app', 'ip']);
  }

  private entrySummaryMatched(entry: VaultEntry): boolean {
    return this.textContainsTerms(this.entrySummary(entry), [
      'any', 'name', 'service', 'server', 'app', 'ip', 'address', 'port',
      'username', 'account', 'notes'
    ]);
  }

  private entryCategoryMatched(entry: VaultEntry): boolean {
    const category = this.entryCategory(entry);
    if (category.length === 0) {
      return false;
    }
    if (this.selectedCategory.trim().length > 0 &&
        category.toLowerCase() === this.selectedCategory.trim().toLowerCase()) {
      return true;
    }
    return this.textContainsTerms(category, ['any', 'category']);
  }

  private tagMatched(tag: string): boolean {
    if (this.selectedTag.trim().length > 0 &&
        tag.toLowerCase() === this.selectedTag.trim().toLowerCase()) {
      return true;
    }
    return this.textContainsTerms(tag, ['any', 'tag']);
  }

  private entryMatchLabels(entry: VaultEntry): string[] {
    const labels: string[] = [];
    if (this.entryTitleMatched(entry) && this.searchQuery.trim().length > 0) {
      labels.push('命中标题');
    }
    if (this.entrySummaryMatched(entry) && this.searchQuery.trim().length > 0) {
      labels.push('命中字段');
    }
    if (this.entryCategoryMatched(entry)) {
      labels.push('命中分类');
    }
    const matchedTags = entry.tags.filter((tag: string) => this.tagMatched(tag));
    if (matchedTags.length > 0) {
      labels.push(`命中标签 ${matchedTags.length}`);
    }
    return labels;
  }

  private entryMatchesSearch(
    entry: VaultEntry,
    terms: SearchTerm[],
  ): boolean {
    return terms.every((term: SearchTerm) => {
      return this.entrySearchValues(entry, term.field)
        .some((value: string) => value.toLowerCase().includes(term.value));
    });
  }

  private entrySearchValues(entry: VaultEntry, field: string): string[] {
    const payload = entry.payload as SearchPayload;
    if (field === 'any') {
      const values: string[] = [entry.label, `${entry.type}`, this.entryCategory(entry)];
      entry.tags.forEach((tag: string) => values.push(tag));
      this.addSearchValue(values, payload.name);
      this.addSearchValue(values, payload.username);
      this.addSearchValue(values, payload.appId);
      this.addSearchValue(values, payload.ipAddress);
      this.addSearchValue(values, payload.port);
      this.addSearchValue(values, payload.notes);
      this.addSearchValue(values, payload.connectionAddress);
      this.addSearchValue(values, payload.connectionPort);
      this.addSearchValue(values, payload.accountId);
      this.addSearchArray(values, payload.serverIds);
      this.addSearchAccounts(values, payload.accounts, false);
      entry.customFields.forEach((customField: CustomField) => {
        values.push(customField.name);
        values.push(customField.value);
      });
      return values;
    }
    if (field === 'label') {
      return [entry.label];
    }
    if (field === 'name') {
      const values: string[] = [entry.label];
      this.addSearchValue(values, payload.name);
      return values.concat(this.customFieldValues(entry, 'name'));
    }
    if (field === 'type') {
      return [`${entry.type}`];
    }
    if (field === 'category') {
      return [this.entryCategory(entry)];
    }
    if (field === 'tag') {
      return entry.tags;
    }
    if (field === 'username') {
      const values: string[] = [];
      this.addSearchValue(values, payload.username);
      this.addSearchAccounts(values, payload.accounts, false, true);
      return values.concat(this.customFieldValues(entry, 'username'));
    }
    if (field === 'ip') {
      const values: string[] = [];
      this.addSearchValue(values, payload.ipAddress);
      this.addSearchValue(values, payload.connectionAddress);
      return values.concat(this.customFieldValues(entry, 'ip'));
    }
    if (field === 'port') {
      const values: string[] = [];
      this.addSearchValue(values, payload.port);
      this.addSearchValue(values, payload.connectionPort);
      return values.concat(this.customFieldValues(entry, 'port'));
    }
    if (field === 'address') {
      const values: string[] = [];
      this.addSearchValue(values, payload.ipAddress);
      this.addSearchValue(values, payload.connectionAddress);
      return values.concat(this.customFieldValues(entry, 'address'));
    }
    if (field === 'app') {
      const values: string[] = [];
      this.addSearchValue(values, payload.appId);
      return values.concat(this.customFieldValues(entry, 'app'));
    }
    if (field === 'account') {
      const values: string[] = [];
      this.addSearchValue(values, payload.accountId);
      this.addSearchAccounts(values, payload.accounts, false);
      return values.concat(this.customFieldValues(entry, 'account'));
    }
    if (field === 'server') {
      const values: string[] = [];
      if (entry.type === VaultEntryType.SERVER) {
        values.push(entry.label);
      }
      this.addSearchValue(values, payload.name);
      this.addSearchValue(values, payload.ipAddress);
      this.addSearchArray(values, payload.serverIds);
      return values.concat(this.customFieldValues(entry, 'server'));
    }
    if (field === 'service') {
      const values: string[] = [];
      if (entry.type === VaultEntryType.SERVICE) {
        values.push(entry.label);
      }
      this.addSearchValue(values, payload.name);
      this.addSearchValue(values, payload.connectionAddress);
      return values.concat(this.customFieldValues(entry, 'service'));
    }
    if (field === 'notes') {
      const values: string[] = [];
      this.addSearchValue(values, payload.notes);
      this.addSearchAccounts(values, payload.accounts, false, false, true);
      return values.concat(this.customFieldValues(entry, 'notes'));
    }
    if (field === 'password') {
      const values: string[] = [];
      this.addSearchValue(values, payload.password);
      this.addSearchAccounts(values, payload.accounts, true);
      return values.concat(this.customFieldValues(entry, 'password'));
    }
    if (field === 'token') {
      const values: string[] = [];
      this.addSearchValue(values, payload.token);
      return values.concat(this.customFieldValues(entry, 'token'));
    }
    if (field === 'accesskey') {
      const values: string[] = [];
      this.addSearchValue(values, payload.accessKey);
      return values.concat(this.customFieldValues(entry, 'accesskey'));
    }
    if (field === 'secret') {
      const values: string[] = [];
      this.addSearchValue(values, payload.secretKey);
      return values.concat(this.customFieldValues(entry, 'secret'));
    }
    if (field === 'custom') {
      const values: string[] = [];
      entry.customFields.forEach((customField: CustomField) => {
        values.push(customField.name);
        values.push(customField.value);
      });
      return values;
    }
    return this.customFieldValues(entry, field);
  }

  private customFieldValues(entry: VaultEntry, field: string): string[] {
    const key = this.normalizeSearchField(field);
    const values: string[] = [];
    entry.customFields.forEach((customField: CustomField) => {
      const customKey = this.normalizeSearchField(customField.name);
      if (customKey.length > 0 &&
          (customKey === key || customKey.includes(key) || key.includes(customKey))) {
        values.push(customField.name);
        values.push(customField.value);
      }
    });
    return values;
  }

  private addSearchValue(values: string[], value: string | undefined): void {
    if (typeof value === 'string' && value.length > 0) {
      values.push(value);
    }
  }

  private addSearchArray(values: string[], items: string[] | undefined): void {
    if (items !== undefined) {
      items.forEach((item: string) => this.addSearchValue(values, item));
    }
  }

  private addSearchAccounts(
    values: string[],
    accounts: SearchServiceAccount[] | undefined,
    includePasswords: boolean,
    includeUsernames: boolean = true,
    includeNotes: boolean = true,
  ): void {
    if (accounts === undefined) {
      return;
    }
    accounts.forEach((account: SearchServiceAccount) => {
      if (includeUsernames) {
        this.addSearchValue(values, account.username);
      }
      if (includeNotes) {
        this.addSearchValue(values, account.note);
      }
      if (includePasswords) {
        this.addSearchValue(values, account.password);
      }
    });
  }

  private entryCategory(entry: VaultEntry): string {
    const carrier = entry as EntryCategoryCarrier;
    const payload = entry.payload as SearchPayload;
    return this.firstNonEmptyString([
      this.cleanString(payload.category),
      this.cleanString(payload.metadataCategory),
      this.cleanString(carrier.category),
      this.cleanString(carrier.metadataCategory),
    ]);
  }

  private cleanString(value: string | undefined): string {
    return typeof value === 'string' ? value.trim() : '';
  }

  private firstNonEmptyString(values: string[]): string {
    for (let index = 0; index < values.length; index++) {
      const value = values[index];
      if (value.length > 0) {
        return value;
      }
    }
    return '';
  }

  @Builder
  private CategoryDraftPills(
    selectedCategory: string,
    onSelected: (category: string) => void
  ) {
    Flex({ wrap: FlexWrap.Wrap }) {
      this.FilterPill('未分类', selectedCategory.length === 0, () => {
        onSelected('');
      });
      ForEach(this.categories, (category: string) => {
        this.FilterPill(category, selectedCategory === category, () => {
          onSelected(category);
        });
      }, (category: string) => category);
    }
  }

  @Builder
  private FilterPill(label: string, selected: boolean, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontWeight(FontWeight.Bold)
      .fontColor(selected ? '#FFFFFF' : UI_TEXT)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .margin({ right: 8, bottom: 8 })
      .backgroundColor(selected ? UI_ACCENT : UI_SURFACE_ALT)
      .border({ width: 1, color: selected ? UI_ACCENT : UI_STROKE })
      .borderRadius(999)
      .onClick(action);
  }

  private handleCategoryFilterSelection(category: string): void {
    this.dismissSearchEditing();
    const clean = category.trim();
    this.selectedCategory = this.selectedCategory === clean ? '' : clean;
  }

  private handleTagFilterSelection(tag: string): void {
    this.dismissSearchEditing();
    const clean = tag.trim();
    this.selectedTag = this.selectedTag === clean ? '' : clean;
  }

  private dismissSearchEditing(): void {
    try {
      this.searchInputController.stopEditing();
    } catch (_) {
    }
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
    const clean = message.trim();
    if (clean.length === 0) {
      return;
    }
    const version = this.toastVersion + 1;
    this.toastVersion = version;
    this.toastMessage = clean;
    setTimeout(() => {
      if (this.toastVersion === version) {
        this.toastMessage = '';
      }
    }, 2000);
  }

  private schedulePostUnlockRefresh(): void {
    setTimeout(() => {
      if (!this.unlocked) {
        return;
      }
      this.refreshData();
      this.refreshSyncState();
    }, 600);
    setTimeout(() => {
      if (!this.unlocked) {
        return;
      }
      this.refreshData();
      this.refreshSyncState();
    }, 2500);
  }
}

function clampInteger(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) {
    return min;
  }
  return Math.min(Math.max(Math.floor(value), min), max);
}
