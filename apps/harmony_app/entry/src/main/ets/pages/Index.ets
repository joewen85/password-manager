import { Context } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { window } from '@kit.ArkUI';
import display from '@ohos.display';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import {
  CategoryTemplate,
  CategoryTypePreset,
  CreateCredentialInput,
  CreateServerInput,
  CreateServiceInput,
  CredentialPayload,
  CustomField,
  FieldTemplate,
  SecuritySettings,
  ServerPayload,
  ServicePayload,
  VaultEntry,
  VaultEntryType
} from '../src/model/VaultTypes';
import {
  BackupInfo,
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
import { isEditableCategoryFieldType } from '../src/domain/CategoryTemplateEditing';
import {
  EntryReferenceResolution,
  EntryReferenceStatus,
} from '../src/domain/FieldReferenceResolver';
import {
  canExposeRawCustomFieldValue,
  EntryReferenceCandidate,
  entryReferenceCandidates,
  safeCustomFieldSearchValues as referenceSafeCustomFieldSearchValues,
} from '../src/domain/EntryReferenceOperations';

type DraftType = 'credential' | 'server' | 'service';
type ActivePanel = 'home' | 'category' | 'tag';
type TopOverlayPanel = 'none' | 'create' | 'settings' | 'more' | 'backup' | 'clearData' | 'categorySelect' | 'categoryCreate' | 'tagCreate' | 'entryEditor' | 'entryReferenceSelect' | 'entryDetail';
const MAX_UNLOCK_ATTEMPTS: number = 5;
const WIDE_LAYOUT_MIN_WIDTH: number = 720;
const EXPANDED_LAYOUT_MIN_WIDTH: number = 960;
const UI_BACKGROUND: Resource = $r('app.color.ui_background');
const UI_SURFACE: Resource = $r('app.color.ui_surface');
const UI_SURFACE_ALT: Resource = $r('app.color.ui_surface_alt');
const UI_TEXT: Resource = $r('app.color.ui_text');
const UI_MUTED: Resource = $r('app.color.ui_muted');
const UI_STROKE: Resource = $r('app.color.ui_stroke');
const UI_ACCENT: Resource = $r('app.color.ui_accent');
const UI_SELECTED: Resource = $r('app.color.ui_selected');
const UI_DANGER: Resource = $r('app.color.ui_danger');
const UI_DANGER_SURFACE: Resource = $r('app.color.ui_danger_surface');
const KEYBOARD_BASELINE_DROP_GUARD: number = 160;
const VIEWPORT_WIDTH_RESIZE_TOLERANCE: number = 48;
const KEYBOARD_INSET_TOLERANCE: number = 64;

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

interface CategoryFieldTypeState {
  fieldId: string;
  valueType: string;
  readOnly: boolean;
  typeLocked: boolean;
}

interface DraftCustomFieldCategoryState {
  fieldId: string;
  category: string;
}

@Entry
@Component
struct Index {
  private vaultController: VaultController | null = null;
  private biometricCredentialStore: BiometricCredentialStore | null = null;
  private hostContext: Context | null = null;
  private searchInputController: TextInputController = new TextInputController();
  private entryListScroller: Scroller = new Scroller();
  private appWindow: window.Window | null = null;
  private keyboardHeightChangeHandler: (height: number) => void = (height: number) => {
    this.keyboardHeight = Math.max(0, height);
  };
  private foldStatusChangeHandler: (status: display.FoldStatus) => void = (_status: display.FoldStatus) => {
    this.updateFoldableState();
  };
  private autoSyncTimerId: number = -1;
  private idleLockTimerId: number = -1;
  private lastActivityAt: number = Date.now();
  private biometricAutoPrompted: boolean = false;

  @State private ready: boolean = false;
  @State private hasMasterKey: boolean = false;
  @State private unlocked: boolean = false;
  @State private activePanel: ActivePanel = 'home';
  @State private topOverlayPanel: TopOverlayPanel = 'none';
  @State private entryEditorVisible: boolean = false;
  @State private viewportWidth: number = 0;
  @State private viewportHeight: number = 0;
  @State private keyboardBaselineViewportHeight: number = 0;
  @State private foldableDevice: boolean = false;
  @State private currentFoldStatus: number = 0;
  @State private keyboardHeight: number = 0;

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
  @State private syncObjectStorageAccessKeyId: string = '';
  @State private syncObjectStorageSecretAccessKey: string = '';
  @State private syncObjectStorageBucket: string = '';
  @State private syncObjectStorageEndpoint: string = '';
  @State private syncObjectStorageAppId: string = '';
  @State private syncObjectStorageCustomUrl: string = '';
  @State private syncObjectStorageObjectKey: string = 'vault.sync.json';
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
  @State private selectedEntryId: string = '';
  @State private entryListFirstVisibleIndex: number = 0;

  @State private entries: VaultEntry[] = [];
  @State private tags: string[] = [];
  @State private categories: string[] = [];
  @State private categoryTemplates: CategoryTemplate[] = [];

  @State private tagDraft: string = '';
  @State private categoryDraft: string = '';
  @State private categoryCreateReturnToEntry: boolean = false;
  @State private categorySelectReturnToEntry: boolean = false;
  @State private categoryRenameSource: string = '';
  @State private categoryDraftCustomFields: CustomField[] = [];
  @State private categoryDraftFieldTypes: CategoryFieldTypeState[] = [];
  @State private clearDataPassword: string = '';
  @State private backups: BackupInfo[] = [];
  @State private backupBusy: boolean = false;

  @State private draftType: DraftType = 'credential';
  @State private draftLabel: string = '';
  @State private draftCategory: string = '';
  @State private draftCategorySearch: string = '';
  @State private draftTagSearch: string = '';
  @State private draftSelectedTags: string[] = [];
  @State private draftCustomFields: CustomField[] = [];
  @State private draftProtectedCustomFieldIds: string[] = [];
  @State private draftCustomFieldCategories: DraftCustomFieldCategoryState[] = [];
  @State private draftReferenceFieldId: string = '';
  @State private draftReferenceSearch: string = '';
  @State private editingEntryId: string = '';
  @State private exportEntryId: string = '';
  @State private exportSelectedFieldIds: string[] = [];

  async aboutToAppear(): Promise<void> {
    const crypto = new VaultCryptoService();
    try {
      const hostContext = this.getUIContext().getHostContext() as Context;
      this.hostContext = hostContext;
      const persistentStore = await PreferencesVaultStore.create(hostContext);
      this.vaultController = new VaultController(persistentStore, crypto, hostContext);
      this.biometricCredentialStore = await BiometricCredentialStore.create(hostContext);
    } catch (error) {
      console.error(`Preferences store unavailable, fallback to memory: ${error}`);
      this.vaultController = new VaultController(new InMemoryVaultStore(), crypto, this.hostContext);
      this.biometricCredentialStore = null;
    }
    if (this.hostContext !== null) {
      await this.bindKeyboardAvoidance(this.hostContext);
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
    this.configureFoldableState();
    this.scheduleBiometricUnlockPrompt();
  }

  aboutToDisappear(): void {
    this.unbindKeyboardAvoidance();
    this.stopAutoSyncTimer();
    this.stopIdleLockTimer();
    this.stopFoldableState();
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
        .fontWeight(FontWeight.Bold)
        .fontColor(UI_TEXT);

      Text(this.hasMasterKey && this.biometricUnlockEnabled && this.biometricUnlockAvailable && this.biometricFailureCount < 3
        ? '正在调用生物识别；失败 3 次后请输入主密码。'
        : (this.hasMasterKey ? '请输入主密码继续。' : '首次使用，请设置主密码。'))
        .fontSize(14)
        .fontColor(UI_MUTED);

      TextInput({ placeholder: '主密码', text: $$this.password })
        .type(InputType.Password)
        .width('100%')
        .height(48)
        .backgroundColor(UI_SURFACE_ALT)
        .fontColor(UI_TEXT)
        .placeholderColor(UI_MUTED)
        .caretColor(UI_ACCENT)
        .onFocus(() => {
          this.scheduleKeyboardAvoidAreaSync();
        })
        .border({ width: 1, color: UI_STROKE })
        .borderRadius(12)
        .padding({ left: 12, right: 12 });

      if (!this.hasMasterKey) {
        TextInput({ placeholder: '确认主密码', text: $$this.confirmPassword })
          .type(InputType.Password)
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 12, right: 12 });
      }

      if (this.hasMasterKey) {
        TextInput({ placeholder: '动态验证码(启用2FA后必填)', text: $$this.unlockTotpCode })
          .type(InputType.Number)
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 12, right: 12 });

        if (this.unlockRemainingSeconds > 0) {
          Text(`解锁暂时受限，请在 ${this.unlockRemainingSeconds} 秒后重试`)
            .fontSize(12)
            .fontColor(UI_DANGER);
        } else if (this.unlockFailedAttempts > 0) {
          Text(`剩余尝试次数 ${this.remainingUnlockAttempts()} 次`)
            .fontSize(12)
            .fontColor(UI_DANGER);
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
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 10 }) {
        this.HeaderSection();
        if (this.activePanel === 'category') {
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
          this.HomeContent();
        }
      }
      .width('100%')
      .height('100%');

      if (this.topOverlayPanel !== 'none') {
        this.FloatingPanelScrim();
        this.FloatingPanel();
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.updateViewportSize(newValue);
    });
  }

  @Builder
  private HomeContent() {
    if (this.useWideLayout() && !this.entryEditorVisible) {
      Row({ space: 12 }) {
        Column({ space: 10 }) {
          this.StatusSummary();
          this.FilterSection();
          this.EntryListSection();
        }
        .height('100%')
        .width(this.primaryPaneWidth())
        .constraintSize({ minWidth: this.primaryPaneMinWidth(), maxWidth: this.primaryPaneMaxWidth() });
        this.EntryDetailSection();
      }
      .layoutWeight(1)
      .width('100%')
      .alignItems(VerticalAlign.Top);
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

  @Builder
  private HeaderSection() {
    if (this.useWideLayout() && this.activePanel === 'home' && !this.entryEditorVisible) {
      Row() {
        Column() {
          this.HeaderToolbarContent();
        }
        .width(this.primaryPaneWidth())
        .constraintSize({ minWidth: this.primaryPaneMinWidth(), maxWidth: this.primaryPaneMaxWidth() });
        Blank();
      }
      .width('100%')
      .padding({ left: 2, right: 2, top: 2, bottom: 2 });
    } else {
      Column() {
        this.HeaderToolbarContent();
      }
      .width('100%')
      .padding({ left: 2, right: 2, top: 2, bottom: 2 });
    }
  }

  @Builder
  private HeaderToolbarContent() {
    Row() {
      Column({ space: 4 }) {
        Text('密码管理器')
          .fontSize(this.headerTitleFontSize())
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        if (this.showHeaderSubtitle()) {
          Text('鸿蒙原生密码库')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor(UI_ACCENT)
            .padding({ left: 9, right: 9, top: 4, bottom: 4 })
            .backgroundColor(UI_SURFACE_ALT)
            .borderRadius(999);
        }
      }
      .layoutWeight(1)
      .constraintSize({ minWidth: 0 })
      .alignItems(HorizontalAlign.Start);
      Row() {
        this.ToolbarIconButton('+', '添加', true, () => {
          this.openTopOverlay('create');
        });
        this.ToolbarIconButton(this.syncBusy ? '···' : '↻', '同步', false, () => {
          if (!this.syncBusy) {
            this.onSyncNow();
          }
        });
        this.ToolbarIconButton('☁', '备份', this.topOverlayPanel === 'backup', () => {
          this.openTopOverlay('backup');
        });
        this.ToolbarIconButton('⋮', '更多', this.topOverlayPanel === 'more', () => {
          this.openTopOverlay('more');
        });
        this.ToolbarIconButton('🔒', '锁定', false, () => {
          this.lockVault();
        });
      }
      .constraintSize({ minWidth: this.toolbarActionsMinWidth() });
    }
    .width('100%')
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  private ToolbarIconButton(icon: string, label: string, accent: boolean, action: () => void) {
    Text(icon)
      .fontSize(this.toolbarIconFontSize(icon))
      .fontWeight(FontWeight.Bold)
      .fontColor(accent ? UI_ACCENT : UI_TEXT)
      .width(this.toolbarIconSize())
      .height(this.toolbarIconSize())
      .margin({ left: 2 })
      .textAlign(TextAlign.Center)
      .backgroundColor(accent ? UI_SELECTED : UI_SURFACE)
      .border({ width: 1, color: accent ? UI_ACCENT : UI_STROKE })
      .borderRadius(12)
      .accessibilityText(label)
      .onClick(action);
  }

  @Builder
  private FloatingPanelScrim() {
    Column() {}
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(24, 31, 42, 0.16)')
      .zIndex(8)
      .onClick(() => {
        this.closeTopOverlay();
      });
  }

  @Builder
  private FloatingPanel() {
    if (this.floatingPanelUsesAvailableHeight()) {
      Column({ space: 10 }) {
        this.FloatingPanelContent();
      }
      .width(this.floatingPanelWidth())
      .height(this.floatingPanelMaxHeight())
      .padding(14)
      .backgroundColor(UI_SURFACE)
      .border({ width: 1, color: UI_STROKE })
      .borderRadius(18)
      .position({ x: this.floatingPanelX(), y: this.floatingPanelY() })
      .zIndex(9);
    } else {
      Column({ space: 10 }) {
        this.FloatingPanelContent();
      }
      .width(this.floatingPanelWidth())
      .constraintSize({ maxHeight: this.floatingPanelMaxHeight() })
      .padding(14)
      .backgroundColor(UI_SURFACE)
      .border({ width: 1, color: UI_STROKE })
      .borderRadius(18)
      .position({ x: this.floatingPanelX(), y: this.floatingPanelY() })
      .zIndex(9);
    }
  }

  @Builder
  private FloatingPanelContent() {
    if (this.topOverlayPanel === 'create') {
      this.CreateOverlayPanel();
    } else if (this.topOverlayPanel === 'settings') {
      this.SettingsOverlayPanel();
    } else if (this.topOverlayPanel === 'more') {
      this.MoreOverlayPanel();
    } else if (this.topOverlayPanel === 'backup') {
      this.BackupOverlayPanel();
    } else if (this.topOverlayPanel === 'clearData') {
      this.ClearDataOverlayPanel();
    } else if (this.topOverlayPanel === 'categorySelect') {
      this.CategorySelectOverlayPanel();
    } else if (this.topOverlayPanel === 'categoryCreate') {
      this.CategoryCreateOverlayPanel();
    } else if (this.topOverlayPanel === 'tagCreate') {
      this.TagCreateOverlayPanel();
    } else if (this.topOverlayPanel === 'entryReferenceSelect') {
      this.EntryReferenceSelectOverlayPanel();
    } else if (this.topOverlayPanel === 'entryDetail') {
      this.EntryDetailOverlayPanel();
    } else if (this.topOverlayPanel === 'entryEditor') {
      this.EntryEditorOverlayPanel();
    }
  }

  @Builder
  private FloatingPanelHeader(title: string) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(UI_TEXT);
      Blank();
      this.SmallGhostButton('关闭', () => {
        this.closeTopOverlay();
      });
    }
    .width('100%');
  }

  @Builder
  private CreateOverlayPanel() {
    Column({ space: 10 }) {
      this.FloatingPanelHeader('添加');
      this.OverlayActionButton('新建条目', true, () => {
        this.beginCreateEntry();
      });
      this.OverlayActionButton('创建分类', false, () => {
        this.prepareCreateCategoryOverlay('', false);
      });
      this.OverlayActionButton('创建标签', false, () => {
        this.prepareCreateTagOverlay('');
      });
    }
    .width('100%');
  }

  @Builder
  private SettingsOverlayPanel() {
    Column({ space: 10 }) {
      this.FloatingPanelHeader('设置');
      Scroll() {
        Column({ space: 12 }) {
          this.SecuritySection();
          this.SyncSection();
          this.DeviceSection();
        }
        .width('100%')
        .padding({ bottom: 4 });
      }
      .width('100%')
      .height(this.settingsPanelScrollHeight());
    }
    .width('100%');
  }

  @Builder
  private MoreOverlayPanel() {
    Column({ space: 10 }) {
      this.FloatingPanelHeader('更多');
      this.OverlayActionButton('导出数据', false, () => {
        this.onExportVault();
        this.closeTopOverlay();
      });
      this.OverlayActionButton('导入条目', false, () => {
        this.onImportEntry();
        this.closeTopOverlay();
      });
      this.OverlayActionButton('导入分类', false, () => {
        this.onImportCategory();
        this.closeTopOverlay();
      });
      this.OverlayActionButton('分类管理', false, () => {
        this.openMainPanel('category');
      });
      this.OverlayActionButton('标签管理', false, () => {
        this.openMainPanel('tag');
      });
      this.OverlayActionButton('设置', false, () => {
        this.openTopOverlay('settings');
      });
      this.OverlayActionButton('清空数据', false, () => {
        this.openClearDataOverlay();
      });
    }
    .width('100%');
  }

  @Builder
  private BackupOverlayPanel() {
    Column({ space: 10 }) {
      this.FloatingPanelHeader('备份');
      Text('加密本地备份保存在应用私有存储中，并保留最近 5 个。')
        .fontSize(13)
        .fontColor(UI_MUTED);
      this.OverlayActionButton(this.backupBusy ? '备份中...' : '立即创建备份', true, () => {
        this.onRunBackup();
      });
      Text('可用备份')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(UI_ACCENT);
      if (this.backups.length === 0) {
        Text('尚未创建备份。')
          .fontSize(13)
          .fontColor(UI_MUTED);
      } else {
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.backups, (backup: BackupInfo) => {
              this.BackupRow(backup);
            }, (backup: BackupInfo) => backup.fileName);
          }
          .width('100%');
        }
        .width('100%')
        .height(this.backupListHeight());
      }
    }
    .width('100%');
  }

  @Builder
  private BackupRow(backup: BackupInfo) {
    Column({ space: 6 }) {
      Text(backup.fileName)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(UI_TEXT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
      Text(`${this.formatBytes(backup.sizeBytes)} · ${this.formatBackupTime(backup.modifiedAt)}`)
        .fontSize(12)
        .fontColor(UI_MUTED)
        .width('100%');
      this.SecondaryTextButton('恢复此备份', () => {
        this.onRestoreBackup(backup);
      });
    }
    .width('100%')
    .padding(10)
    .backgroundColor(UI_SURFACE_ALT)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(12);
  }

  @Builder
  private ClearDataOverlayPanel() {
    Column({ space: 10 }) {
      this.FloatingPanelHeader('清空数据');
      Text('将清空所有条目、分类、标签和密码库安全设置。请输入创建时使用的主密码确认。')
        .fontSize(13)
        .fontColor(UI_MUTED);
      TextInput({ placeholder: '主密码', text: $$this.clearDataPassword })
        .type(InputType.Password)
        .width('100%')
        .height(48)
        .backgroundColor(UI_SURFACE_ALT)
        .fontColor(UI_TEXT)
        .placeholderColor(UI_MUTED)
        .caretColor(UI_ACCENT)
        .onFocus(() => {
          this.scheduleKeyboardAvoidAreaSync();
        })
        .border({ width: 1, color: UI_STROKE })
        .borderRadius(12)
        .padding({ left: 14, right: 14 });
      this.OverlayActionButton('确认清空', true, () => {
        this.onClearDataConfirm();
      });
    }
    .width('100%');
  }

  @Builder
  private CategorySelectOverlayPanel() {
    Column({ space: 10 }) {
      this.FloatingPanelHeader('分类');
      Row({ space: 8 }) {
        TextInput({ placeholder: '搜索分类', text: $$this.draftCategorySearch })
          .layoutWeight(1)
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
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
              this.prepareCreateCategoryOverlay(this.draftCategorySearch.trim(), true);
            }
          });
      }
      Scroll() {
        Column({ space: 8 }) {
          if (this.showUncategorizedDraftCategory()) {
            this.CategorySelectRow('', this.draftCategory.length === 0);
          }
          if (this.filteredDraftCategories().length > 0) {
            ForEach(this.filteredDraftCategories(), (category: string) => {
              this.CategorySelectRow(category, this.draftCategory === category);
            }, (category: string) => category);
          } else if (!this.showUncategorizedDraftCategory()) {
            Text('没有匹配分类，可点击 + 创建。')
              .fontSize(13)
              .fontColor(UI_MUTED);
          }
        }
        .width('100%');
      }
      .width('100%')
      .height(this.categorySelectListHeight());
    }
    .width('100%');
  }

  @Builder
  private CategorySelectRow(category: string, selected: boolean) {
    Row({ space: 8 }) {
      Text(this.categoryDisplayName(category))
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(selected ? '#FFFFFF' : UI_TEXT)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
      if (selected) {
        Text('✓')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF');
      }
    }
    .height(44)
    .width('100%')
    .padding({ left: 14, right: 14 })
    .backgroundColor(selected ? UI_ACCENT : UI_SURFACE_ALT)
    .border({ width: 1, color: selected ? UI_ACCENT : UI_STROKE })
    .borderRadius(12)
    .onClick(() => {
      this.selectDraftCategory(category);
      this.closeTopOverlay();
    });
  }

  @Builder
  private EntryReferenceSelectOverlayPanel() {
    Column({ space: 10 }) {
      this.FloatingPanelHeader(this.entryReferenceSelectorTitle());
      Text(this.entryReferenceSelectorHint())
        .fontSize(12)
        .fontColor(UI_MUTED)
        .width('100%');
      TextInput({ placeholder: '搜索条目名称或分类', text: $$this.draftReferenceSearch })
        .width('100%')
        .height(48)
        .backgroundColor(UI_SURFACE_ALT)
        .fontColor(UI_TEXT)
        .placeholderColor(UI_MUTED)
        .caretColor(UI_ACCENT)
        .onFocus(() => {
          this.scheduleKeyboardAvoidAreaSync();
        })
        .border({ width: 1, color: UI_STROKE })
        .borderRadius(12)
        .padding({ left: 14, right: 14 });
      if (this.activeDraftReferenceValue().length > 0) {
        this.SecondaryTextButton('清除关联', () => {
          this.clearActiveDraftReference();
        });
      }
      Scroll() {
        Column({ space: 8 }) {
          if (this.filteredEntryReferenceCandidates().length === 0) {
            Text(this.entryReferenceSelectorEmptyText())
              .fontSize(13)
              .fontColor(UI_MUTED)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 28, bottom: 28 });
          } else {
            ForEach(this.filteredEntryReferenceCandidates(), (entry: EntryReferenceCandidate) => {
              this.EntryReferenceSelectRow(
                entry,
                this.activeDraftReferenceValue() === entry.id,
              );
            }, (entry: EntryReferenceCandidate) => entry.id);
          }
        }
        .width('100%');
      }
      .width('100%')
      .height(this.entryReferenceSelectListHeight());
    }
    .width('100%');
  }

  @Builder
  private EntryReferenceSelectRow(entry: EntryReferenceCandidate, selected: boolean) {
    Row({ space: 8 }) {
      Column({ space: 3 }) {
        Text(entry.label)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(selected ? '#FFFFFF' : UI_TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        Text(entry.category.length > 0 ? entry.category : '未分类')
          .fontSize(12)
          .fontColor(selected ? '#FFFFFF' : UI_MUTED)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
      }
      .layoutWeight(1);
      if (selected) {
        Text('✓')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF');
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(selected ? UI_ACCENT : UI_SURFACE_ALT)
    .border({ width: 1, color: selected ? UI_ACCENT : UI_STROKE })
    .borderRadius(12)
    .onClick(() => {
      this.selectActiveDraftReference(entry.id);
    });
  }

  @Builder
  private CategoryCreateOverlayPanel() {
    Column({ space: 10 }) {
      this.FloatingPanelHeader('创建分类');
      Scroll() {
        Column({ space: 10 }) {
          TextInput({ placeholder: '分类名称（必填）', text: $$this.categoryDraft })
            .width('100%')
            .height(48)
            .backgroundColor(UI_SURFACE_ALT)
            .fontColor(UI_TEXT)
            .placeholderColor(UI_MUTED)
            .caretColor(UI_ACCENT)
            .onFocus(() => {
              this.scheduleKeyboardAvoidAreaSync();
            })
            .border({ width: 1, color: UI_STROKE })
            .borderRadius(12)
            .padding({ left: 14, right: 14 });
          if (!this.categoryCreateReturnToEntry) {
            Text('字段快捷键')
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor(UI_MUTED);
            Flex({ wrap: FlexWrap.Wrap }) {
              this.ChoiceChip('服务器', false, () => {
                this.addCategoryDraftShortcutFields(CategoryTypePreset.SERVER);
              });
              this.ChoiceChip('服务', false, () => {
                this.addCategoryDraftShortcutFields(CategoryTypePreset.SERVICE);
              });
              this.ChoiceChip('账号', false, () => {
                this.addCategoryDraftShortcutFields(CategoryTypePreset.ACCOUNT);
              });
            }
          }
          this.CategoryDraftCustomFieldsEditor();
          this.PrimaryTextButton('保存分类', () => {
            this.onAddCategoryFromOverlay();
          });
        }
        .width('100%');
      }
      .width('100%')
      .height(this.categoryCreatePanelScrollHeight());
    }
    .width('100%');
  }

  @Builder
  private TagCreateOverlayPanel() {
    Column({ space: 10 }) {
      this.FloatingPanelHeader('创建标签');
      TextInput({ placeholder: '标签名称（必填）', text: $$this.tagDraft })
        .width('100%')
        .height(48)
        .backgroundColor(UI_SURFACE_ALT)
        .fontColor(UI_TEXT)
        .placeholderColor(UI_MUTED)
        .caretColor(UI_ACCENT)
        .onFocus(() => {
          this.scheduleKeyboardAvoidAreaSync();
        })
        .border({ width: 1, color: UI_STROKE })
        .borderRadius(12)
        .padding({ left: 14, right: 14 });
      this.PrimaryTextButton('保存标签', () => {
        this.onAddTagFromOverlay();
      });
    }
    .width('100%');
  }

  @Builder
  private OverlayActionButton(label: string, primary: boolean, action: () => void) {
    Text(label)
      .fontSize(14)
      .fontWeight(FontWeight.Bold)
      .fontColor(primary ? '#FFFFFF' : UI_TEXT)
      .height(44)
      .width('100%')
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
        .fontColor(UI_TEXT)
        .placeholderColor(UI_MUTED)
        .caretColor(UI_ACCENT)
        .onFocus(() => {
          this.scheduleKeyboardAvoidAreaSync();
        })
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
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
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
        .fontColor(UI_TEXT)
        .placeholderColor(UI_MUTED)
        .caretColor(UI_ACCENT)
        .onFocus(() => {
          this.scheduleKeyboardAvoidAreaSync();
        })
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
        this.ChoiceChip('腾讯云 COS', this.syncProviderType === SyncProviderType.TENCENT_COS, () => {
          this.syncProviderType = SyncProviderType.TENCENT_COS;
        });
        this.ChoiceChip('阿里云 OSS', this.syncProviderType === SyncProviderType.ALIYUN_OSS, () => {
          this.syncProviderType = SyncProviderType.ALIYUN_OSS;
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
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: '路径，例如 /vault.json', text: $$this.syncWebdavPath })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: '用户名，可选', text: $$this.syncWebdavUsername })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: '密码，可选', text: $$this.syncWebdavPassword })
          .type(InputType.Password)
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
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
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: '上传 URL', text: $$this.syncPresignedUploadUrl })
          .type(InputType.Password)
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
      }

      if (
        this.syncProviderType === SyncProviderType.TENCENT_COS ||
        this.syncProviderType === SyncProviderType.ALIYUN_OSS
      ) {
        this.SectionTitle(this.syncProviderType === SyncProviderType.TENCENT_COS ? '腾讯云 COS 设置' : '阿里云 OSS 设置');
        TextInput({ placeholder: 'Access Key / SecretId（必填）', text: $$this.syncObjectStorageAccessKeyId })
          .type(InputType.Password)
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: 'Secret Key（必填）', text: $$this.syncObjectStorageSecretAccessKey })
          .type(InputType.Password)
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: 'Bucket（必填）', text: $$this.syncObjectStorageBucket })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: this.syncProviderType === SyncProviderType.TENCENT_COS ? 'Endpoint，例如 cos.ap-shanghai.myqcloud.com' : 'Endpoint，例如 oss-cn-hangzhou.aliyuncs.com', text: $$this.syncObjectStorageEndpoint })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        if (this.syncProviderType === SyncProviderType.TENCENT_COS) {
          TextInput({ placeholder: 'AppID，可选；未包含在 bucket 时自动追加', text: $$this.syncObjectStorageAppId })
            .width('100%')
            .height(48)
            .backgroundColor(UI_SURFACE_ALT)
            .fontColor(UI_TEXT)
            .placeholderColor(UI_MUTED)
            .caretColor(UI_ACCENT)
            .onFocus(() => {
              this.scheduleKeyboardAvoidAreaSync();
            })
            .border({ width: 1, color: UI_STROKE })
            .borderRadius(12)
            .padding({ left: 14, right: 14 });
        }
        TextInput({ placeholder: '自定义 URL，可选；填写后优先生效', text: $$this.syncObjectStorageCustomUrl })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        TextInput({ placeholder: '对象 Key，例如 vault.sync.json', text: $$this.syncObjectStorageObjectKey })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
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
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
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
          this.FilterPill('全部分类', this.selectedCategory.trim().length === 0, () => {
            this.handleCategoryFilterSelection('');
          });
          ForEach(this.categories, (category: string) => {
            this.FilterPill(category, this.isFocusedCategory(category), () => {
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
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
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
      this.FloatingPanelHeader(this.editingEntryId.length > 0 ? '编辑条目' : '新建条目');
      this.EntryEditorFormContent();
    }
    .width('100%')
    .padding(16)
    .backgroundColor(UI_SURFACE)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(18);
  }

  @Builder
  private EntryEditorOverlayPanel() {
    Column({ space: 10 }) {
      this.FloatingPanelHeader(this.editingEntryId.length > 0 ? '编辑条目' : '新建条目');
      Scroll() {
        Column({ space: 10 }) {
          this.EntryEditorFormContent();
        }
        .width('100%')
        .padding({ bottom: 4 });
      }
      .width('100%')
      .height(this.entryEditorPanelScrollHeight());
    }
    .width('100%');
  }

  @Builder
  private EntryDetailOverlayPanel() {
    Column({ space: 10 }) {
      this.FloatingPanelHeader('条目详情');
      if (this.selectedDetailEntry() === null) {
        Text('条目不存在或已删除')
          .fontSize(13)
          .fontColor(UI_MUTED)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 32, bottom: 32 });
      } else {
        this.EntryDetailContent(this.selectedDetailEntry() as VaultEntry);
      }
    }
    .width('100%');
  }

  @Builder
  private EntryEditorFormContent() {
    Column({ space: 10 }) {
      TextInput({ placeholder: '名称（必填）', text: $$this.draftLabel })
        .width('100%')
        .height(48)
        .backgroundColor(UI_SURFACE_ALT)
        .fontColor(UI_TEXT)
        .placeholderColor(UI_MUTED)
        .caretColor(UI_ACCENT)
        .onFocus(() => {
          this.scheduleKeyboardAvoidAreaSync();
        })
        .border({ width: 1, color: UI_STROKE })
        .borderRadius(12)
        .padding({ left: 14, right: 14 });

      this.EntryCategorySelect();
      this.EntryTagMultiSelect();

      this.EntryReferenceFieldsEditor();
      this.CustomFieldsEditor();
      this.UnsupportedDraftFieldsNotice();

      this.PrimaryTextButton(this.editingEntryId.length > 0 ? '保存修改' : '保存条目', () => {
        this.onSaveEntry();
      });
    }
    .width('100%');
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
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
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
    Column({ space: 12 }) {
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

      Column({ space: 10 }) {
        Text(this.categoryRenameSource.length > 0 ? `编辑分类: ${this.categoryRenameSource}` : '新增分类')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_MUTED);
        TextInput({ placeholder: '分类名称（必填）', text: $$this.categoryDraft })
          .width('100%')
          .height(48)
          .backgroundColor(UI_SURFACE_ALT)
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .padding({ left: 14, right: 14 });
        Text('字段快捷键')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_MUTED);
        Flex({ wrap: FlexWrap.Wrap }) {
          this.ChoiceChip('服务器', false, () => {
            this.addCategoryDraftShortcutFields(CategoryTypePreset.SERVER);
          });
          this.ChoiceChip('服务', false, () => {
            this.addCategoryDraftShortcutFields(CategoryTypePreset.SERVICE);
          });
          this.ChoiceChip('账号', false, () => {
            this.addCategoryDraftShortcutFields(CategoryTypePreset.ACCOUNT);
          });
        }
        this.CategoryDraftCustomFieldsEditor();
        if (this.categoryRenameSource.length > 0) {
          Row({ space: 8 }) {
            Column() {
              this.SecondaryTextButton('取消编辑', () => {
                this.cancelCategoryEdit();
              });
            }
            .layoutWeight(1);
            Column() {
              this.PrimaryTextButton('保存分类', () => {
                this.onRenameCategory();
              });
            }
            .layoutWeight(1);
          }
        } else {
          this.PrimaryTextButton('添加分类', () => {
            this.onAddCategory();
          });
        }
      }
      .width('100%')
      .padding(12)
      .backgroundColor(UI_SURFACE_ALT)
      .border({ width: 1, color: UI_STROKE })
      .borderRadius(14);

      if (this.categories.length > 0) {
        Column({ space: 10 }) {
          ForEach(this.categories, (category: string) => {
            this.CategoryListRow(category);
          }, (category: string) => category);
        }
        .width('100%');
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
  private CategoryListRow(category: string) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(category)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_TEXT)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(`${this.categoryEntryCount(category)} 条`)
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isEditingCategory(category) || this.isFocusedCategory(category) ? UI_ACCENT : UI_MUTED)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(this.isEditingCategory(category) || this.isFocusedCategory(category) ? UI_SELECTED : UI_SURFACE)
          .border({ width: 1, color: this.isEditingCategory(category) || this.isFocusedCategory(category) ? UI_ACCENT : UI_STROKE })
          .borderRadius(999);
      }
      .width('100%')
      .onClick(() => {
        this.focusCategory(category);
      });
      Text(`字段: ${this.categoryFieldSummary(category)}`)
        .fontSize(12)
        .fontColor(UI_MUTED)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .onClick(() => {
          this.focusCategory(category);
        });
      Row({ space: 8 }) {
        this.CategoryRowActionButton('编辑', true, false, () => {
          this.beginEditCategory(category);
        });
        this.CategoryRowActionButton('导出', false, false, () => {
          this.onExportCategory(category);
        });
        this.CategoryRowActionButton('删除', false, true, () => {
          this.onDeleteCategory(category);
        });
      }
      .width('100%');
    }
    .width('100%')
    .padding(12)
    .backgroundColor(this.isEditingCategory(category) || this.isFocusedCategory(category) ? UI_SELECTED : UI_SURFACE_ALT)
    .border({ width: 1, color: this.isEditingCategory(category) || this.isFocusedCategory(category) ? UI_ACCENT : UI_STROKE })
    .borderRadius(14);
  }

  @Builder
  private CategoryRowActionButton(label: string, primary: boolean, danger: boolean, action: () => void) {
    Text(label)
      .fontSize(12)
      .fontWeight(FontWeight.Bold)
      .fontColor(primary ? '#FFFFFF' : (danger ? UI_DANGER : UI_ACCENT))
      .height(34)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .backgroundColor(primary ? UI_ACCENT : (danger ? UI_DANGER_SURFACE : UI_SURFACE))
      .border({ width: 1, color: primary ? UI_ACCENT : (danger ? UI_DANGER : UI_STROKE) })
      .borderRadius(10)
      .onClick(action);
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
                    .fontColor(this.entryTitleMatched(entry) ? UI_ACCENT : UI_TEXT)
                    .layoutWeight(1);
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
                  if (!this.useWideLayout()) {
                    Text('查看')
                      .fontSize(12)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(UI_ACCENT)
                      .margin({ right: 14 })
                      .onClick(() => {
                        this.openEntryDetailOverlay(entry);
                      });
                  }
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
              .border({ width: 1, color: this.selectedEntryId === entry.id ? UI_ACCENT : UI_STROKE })
              .borderRadius(14)
              .onClick(() => {
                this.selectedEntryId = entry.id;
              });
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
  private EntryDetailSection() {
    Column({ space: 10 }) {
      Row() {
        Text('条目详情')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_TEXT);
      }

      if (this.selectedDetailEntry() === null) {
        Column({ space: 8 }) {
          Text(this.filteredEntries().length === 0 ? '暂无可查看条目' : '选择左侧条目查看详情')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(UI_TEXT);
          Text(this.filteredEntries().length === 0 ? '点左上角 + 创建第一个条目。' : '详情会固定显示在右侧，不再挤占列表位置。')
            .fontSize(13)
            .fontColor(UI_MUTED);
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center);
      } else {
        this.EntryDetailContent(this.selectedDetailEntry() as VaultEntry);
      }
    }
    .layoutWeight(1)
    .height('100%')
    .padding(14)
    .backgroundColor(UI_SURFACE)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(18);
  }

  @Builder
  private EntryDetailContent(entry: VaultEntry) {
    Scroll() {
      Column({ space: 8 }) {
        Text(entry.label)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_TEXT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        this.DetailValueRow('分类', this.entryCategory(entry) || '未分类');
        this.DetailValueRow('标签', entry.tags.length > 0 ? entry.tags.join(', ') : '-');
        if (entry.customFields.length > 0) {
          Text('自定义字段')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(UI_MUTED)
            .margin({ top: 4 });
          ForEach(entry.customFields, (field: CustomField) => {
            if (this.isEntryReferenceCustomField(entry, field)) {
              this.EntryReferenceDetailRow(entry, field);
            } else if (this.isUnsupportedCustomField(entry, field)) {
              this.UnsupportedDetailFieldRow(field);
            } else {
              this.DetailValueRow(field.name.length > 0 ? field.name : '字段', field.value);
            }
          }, (field: CustomField) => field.id);
        }
        Row({ space: 8 }) {
          Column() {
            this.SecondaryTextButton('导出', () => {
              this.toggleExportPanel(entry);
            });
          }
          .layoutWeight(1);
          Column() {
            this.PrimaryTextButton('编辑', () => {
              this.startEditEntry(entry);
            });
          }
          .layoutWeight(1);
        }
        if (this.exportEntryId === entry.id) {
          this.EntryExportPanel(entry);
        }
      }
      .width('100%');
    }
    .layoutWeight(1)
    .width('100%');
  }

  @Builder
  private EntryReferenceDetailRow(entry: VaultEntry, field: CustomField) {
    Column({ space: 6 }) {
      Text(field.name.length > 0 ? field.name : '关联字段')
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor(UI_MUTED)
        .width('100%');
      Text(this.entryReferenceDetailText(entry, field))
        .fontSize(14)
        .fontColor(this.entryReferenceDetailColor(entry, field))
        .width('100%')
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
      Row({ space: 8 }) {
        if (this.entryReferenceTargetCanOpen(entry, field)) {
          Column() {
            this.SecondaryTextButton('查看目标', () => {
              this.openEntryReferenceTarget(entry, field);
            });
          }
          .layoutWeight(1);
        }
        Column() {
          this.PrimaryTextButton(this.entryReferenceRepairLabel(entry, field), () => {
            this.repairEntryReference(entry, field);
          });
        }
        .layoutWeight(1);
        if (field.value.length > 0) {
          Column() {
            this.SecondaryTextButton('清除关联', () => {
              this.prepareClearEntryReference(entry, field);
            });
          }
          .layoutWeight(1);
        }
      }
      .width('100%');
    }
    .width('100%')
    .padding(10)
    .backgroundColor(UI_SURFACE_ALT)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(12);
  }

  @Builder
  private UnsupportedDetailFieldRow(field: CustomField) {
    Column({ space: 4 }) {
      Text(field.name.length > 0 ? field.name : '未知字段')
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor(UI_MUTED)
        .width('100%');
      Text('当前版本不支持此字段类型，原值已保留。')
        .fontSize(13)
        .fontColor(UI_DANGER)
        .width('100%');
    }
    .width('100%')
    .padding(10)
    .backgroundColor(UI_DANGER_SURFACE)
    .border({ width: 1, color: UI_DANGER })
    .borderRadius(12);
  }

  @Builder
  private DetailValueRow(label: string, value: string) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor(UI_MUTED);
      Text(value.trim().length > 0 ? value : '-')
        .fontSize(14)
        .fontColor(UI_TEXT)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
    }
    .width('100%')
    .padding(10)
    .backgroundColor(UI_SURFACE_ALT)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(12);
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

  private selectedDetailEntry(): VaultEntry | null {
    if (this.selectedEntryId.length === 0) {
      return null;
    }
    const match = this.entries.find((entry: VaultEntry) => entry.id === this.selectedEntryId);
    return match === undefined ? null : match;
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
      this.toast('名称必填');
      return;
    }

    const tags = [...this.draftSelectedTags];
    const category = this.draftCategory.trim();
    const customFields = this.normalizedDraftCustomFields();

    if (this.draftType === 'credential') {
      const input: CreateCredentialInput = {
        label: label,
        username: '',
        password: '',
        accounts: [],
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
        name: '',
        ipAddress: '',
        port: '',
        username: '',
        password: '',
        accounts: [],
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
        name: '',
        connectionAddress: '',
        connectionPort: '',
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
    this.topOverlayPanel = 'none';
    this.refreshData();
    this.toast('已保存');
  }

  private async onDeleteEntry(entryId: string): Promise<void> {
    await this.controller().deleteEntry(entryId);
    if (this.selectedEntryId === entryId) {
      this.selectedEntryId = '';
    }
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
    const tag = this.tagDraft.trim();
    if (tag.length === 0) {
      this.toast('请输入标签名称');
      return;
    }
    if (this.tags.some((existing: string) => existing.toLowerCase() === tag.toLowerCase())) {
      this.toast('标签已存在');
      return;
    }
    await this.controller().addTag(tag);
    this.tagDraft = '';
    this.refreshData();
    this.toast('标签已保存');
  }

  private async onAddTagFromOverlay(): Promise<void> {
    const draft = this.tagDraft.trim();
    await this.onAddTag();
    if (draft.length > 0 && this.tagDraft.trim().length === 0) {
      this.closeTopOverlay();
    }
  }

  private async onAddCategory(): Promise<void> {
    const category = this.categoryDraft.trim();
    if (category.length === 0) {
      this.toast('请输入分类名称');
      return;
    }
    if (this.categories.some((existing: string) => existing.toLowerCase() === category.toLowerCase())) {
      this.toast('分类已存在');
      return;
    }
    await this.controller().addCategoryWithTemplateFields(
      category,
      this.categoryDraftTemplateFieldDefinitions(),
    );
    this.categoryDraft = '';
    this.categoryDraftCustomFields = [];
    this.categoryDraftFieldTypes = [];
    this.categoryRenameSource = '';
    this.refreshData();
    this.toast('分类已保存');
  }

  private async onAddCategoryFromOverlay(): Promise<void> {
    const draft = this.categoryDraft.trim();
    await this.onAddCategory();
    if (draft.length > 0 && this.categoryDraft.trim().length === 0) {
      if (this.categoryCreateReturnToEntry) {
        this.selectDraftCategory(draft);
        this.restoreEntryEditorOverlay();
        return;
      }
      this.closeTopOverlay();
    }
  }

  private async onApplyCategoryPreset(category: string, preset: CategoryTypePreset): Promise<void> {
    const clean = category.trim();
    if (clean.length === 0) {
      this.toast('请先选择分类');
      return;
    }
    await this.controller().applyCategoryPreset(clean, preset);
    this.refreshData();
    this.toast('分类快捷字段已更新');
  }

  private async onRenameCategory(): Promise<void> {
    const source = this.categoryRenameSource.trim();
    const target = this.categoryDraft.trim();
    if (source.length === 0) {
      this.toast('请先选择要编辑的分类');
      return;
    }
    if (target.length === 0) {
      this.toast('请输入分类名称');
      return;
    }
    if (this.categoryNameExistsBesides(source, target)) {
      this.toast('分类已存在');
      return;
    }
    if (source !== target) {
      await this.controller().renameCategory(source, target);
    }
    await this.controller().saveCategoryTemplateFields(
      target,
      this.categoryDraftTemplateFieldDefinitions(),
    );
    if (this.sameCategoryName(this.selectedCategory, source)) {
      this.selectedCategory = target;
    }
    if (this.sameCategoryName(this.draftCategory, source)) {
      this.draftCategory = target;
    }
    this.cancelCategoryEdit();
    this.refreshData();
    this.toast('分类已保存');
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
    if (this.sameCategoryName(this.selectedCategory, category)) {
      this.selectedCategory = '';
    }
    if (this.draftCategory.trim() === category) {
      this.draftCategory = '';
    }
    if (this.sameCategoryName(this.categoryRenameSource, category)) {
      this.cancelCategoryEdit();
    }
    this.refreshData();
  }

  private async onClearDataConfirm(): Promise<void> {
    const password = this.clearDataPassword;
    if (password.trim().length === 0) {
      this.toast('请输入主密码');
      return;
    }
    const cleared = await this.controller().clearAllData(password);
    if (!cleared) {
      this.toast('主密码验证失败');
      return;
    }
    const store = this.biometricCredentialStore;
    if (store !== null) {
      await store.clear();
    }
    this.selectedCategory = '';
    this.selectedTag = '';
    this.selectedEntryId = '';
    this.searchQuery = '';
    this.clearEntryDraft();
    this.clearDataPassword = '';
    this.entryEditorVisible = false;
    this.activePanel = 'home';
    this.closeTopOverlay();
    this.refreshData();
    this.refreshSecurityState();
    this.refreshSyncState();
    await this.refreshBiometricState();
    this.toast('密码库数据已清空');
  }

  private async onRunBackup(): Promise<void> {
    if (this.backupBusy) {
      return;
    }
    this.backupBusy = true;
    try {
      const backup = await this.controller().runBackup();
      this.refreshBackups();
      this.toast(`备份已保存: ${backup.fileName}`);
    } catch (error) {
      this.toast(`备份失败: ${error}`);
    } finally {
      this.backupBusy = false;
    }
  }

  private async onRestoreBackup(backup: BackupInfo): Promise<void> {
    try {
      const prompt = this.uiPromptAction();
      const confirmation = await prompt.showDialog({
        title: '恢复备份',
        message: `恢复 ${backup.fileName}？当前密码库数据会被替换。`,
        buttons: [
          { text: '取消', color: '#666666' },
          { text: '恢复', color: UI_ACCENT, primary: true },
        ],
      });
      if (confirmation.index !== 1) {
        return;
      }
      await this.controller().restoreBackup(backup.fileName);
      this.selectedCategory = '';
      this.selectedTag = '';
      this.selectedEntryId = '';
      this.searchQuery = '';
      this.clearEntryDraft();
      this.entryEditorVisible = false;
      this.activePanel = 'home';
      this.closeTopOverlay();
      this.hasMasterKey = this.controller().hasMasterKey();
      this.refreshData();
      this.refreshSecurityState();
      this.refreshSyncState();
      this.refreshBackups();
      this.toast('恢复完成');
    } catch (error) {
      this.toast(`恢复失败: ${error}`);
    }
  }

  private categoryPresetSelected(category: string, preset: CategoryTypePreset): boolean {
    const names = this.templateFieldNames(category);
    return this.categoryPresetFieldNames(preset).every((name: string) => names.includes(name));
  }

  private categoryPresetFieldNames(preset: CategoryTypePreset): string[] {
    if (preset === CategoryTypePreset.SERVER) {
      return ['IP地址', '端口', '关联账号'];
    }
    if (preset === CategoryTypePreset.SERVICE) {
      return ['服务入口', '关联账号', '关联服务器'];
    }
    return ['入口'];
  }

  private templateFieldNames(category: string): string[] {
    const names = this.templateFieldsForCategory(category)
      .map((field: FieldTemplate) => field.name.trim())
      .filter((name: string) => name.length > 0);
    return names.length > 0 ? names : ['名称', '备注'];
  }

  private templateFieldsForCategory(category: string): FieldTemplate[] {
    const template = this.categoryTemplate(category);
    if (template !== null) {
      return template.fields;
    }
    return [
      { id: 'template_名称', name: '名称', valueType: 'text', targetCategory: '' },
      { id: 'template_备注', name: '备注', valueType: 'text', targetCategory: '' },
    ];
  }

  private templateFieldValueType(field: FieldTemplate): string {
    const valueType = field.valueType;
    if (typeof valueType !== 'string' || valueType.trim().length === 0) {
      return 'text';
    }
    return valueType;
  }

  private isTextTemplateField(field: FieldTemplate): boolean {
    return this.templateFieldValueType(field) === 'text';
  }

  private isEntryReferenceTemplateField(field: FieldTemplate): boolean {
    return this.templateFieldValueType(field) === 'entryReference';
  }

  private categoryTemplate(category: string): CategoryTemplate | null {
    const clean = category.trim().toLowerCase();
    if (clean.length === 0) {
      return null;
    }
    const found = this.categoryTemplates.find(
      (template: CategoryTemplate) => template.category.trim().toLowerCase() === clean,
    );
    return found === undefined ? null : found;
  }

  private beginEditCategory(category: string): void {
    const clean = category.trim();
    if (clean.length === 0) {
      return;
    }
    this.categoryRenameSource = clean;
    this.categoryDraft = clean;
    this.categoryDraftCustomFields = this.categoryTemplateDraftFields(clean);
    this.categoryDraftFieldTypes = this.categoryTemplateDraftFieldTypes(
      clean,
      this.categoryDraftCustomFields,
    );
  }

  private cancelCategoryEdit(): void {
    this.categoryRenameSource = '';
    this.categoryDraft = '';
    this.categoryDraftCustomFields = [];
    this.categoryDraftFieldTypes = [];
  }

  private categoryTemplateDraftFields(category: string): CustomField[] {
    const fields: CustomField[] = [];
    const seen = new Set<string>();
    this.templateFieldsForCategory(category).forEach((templateField: FieldTemplate) => {
      const name = templateField.name.trim();
      const key = name.toLowerCase();
      if (name.length === 0 || this.isBaseCategoryField(name) || seen.has(key)) {
        return;
      }
      let value = '';
      if (!this.isTextTemplateField(templateField)) {
        value = typeof templateField.targetCategory === 'string'
          ? templateField.targetCategory
          : '';
      }
      seen.add(key);
      fields.push({
        id: this.nextUiId(),
        templateFieldId: templateField.id,
        name: name,
        value,
      });
    });
    return fields;
  }

  private categoryTemplateDraftFieldTypes(
    category: string,
    fields: CustomField[],
  ): CategoryFieldTypeState[] {
    const templateFields = this.templateFieldsForCategory(category);
    return fields.map((field: CustomField) => {
      const template = templateFields.find(
        (candidate: FieldTemplate) => candidate.id === field.templateFieldId,
      );
      const valueType = template === undefined
        ? 'text'
        : this.templateFieldValueType(template);
      const state: CategoryFieldTypeState = {
        fieldId: field.id,
        valueType,
        readOnly: !isEditableCategoryFieldType(valueType),
        typeLocked: this.categoryTemplateFieldHasStoredValue(category, field.templateFieldId),
      };
      return state;
    });
  }

  private categoryTemplateFieldHasStoredValue(
    category: string,
    templateFieldId: string | undefined,
  ): boolean {
    if (typeof templateFieldId !== 'string' || templateFieldId.length === 0) {
      return false;
    }
    return this.controller().categoryTemplateFieldHasStoredValue(category, templateFieldId);
  }

  private isBaseCategoryField(name: string): boolean {
    const key = name.trim().toLowerCase();
    return key === '名称' || key === '备注';
  }

  private categoryFieldSummary(category: string): string {
    return this.templateFieldsForCategory(category)
      .map((field: FieldTemplate) => {
        const name = field.name.trim();
        const valueType = this.templateFieldValueType(field);
        if (valueType === 'entryReference') {
          const targetCategory = field.targetCategory?.trim() ?? '';
          return `${name} → ${targetCategory.length > 0 ? targetCategory : '不限分类'}`;
        }
        if (!isEditableCategoryFieldType(valueType)) {
          return `${name}（只读）`;
        }
        return name;
      })
      .filter((name: string) => name.length > 0)
      .join('、');
  }

  private categoryEntryCount(category: string): number {
    const clean = category.trim().toLowerCase();
    if (clean.length === 0) {
      return 0;
    }
    return this.entries.filter((entry: VaultEntry) =>
      !entry.isDeleted && this.entryCategory(entry).toLowerCase() === clean,
    ).length;
  }

  private sameCategoryName(left: string, right: string): boolean {
    return left.trim().toLowerCase() === right.trim().toLowerCase();
  }

  private categoryNameExistsBesides(source: string, target: string): boolean {
    const sourceKey = source.trim().toLowerCase();
    const targetKey = target.trim().toLowerCase();
    return this.categories.some((category: string) => {
      const key = category.trim().toLowerCase();
      return key === targetKey && key !== sourceKey;
    });
  }

  private isEditingCategory(category: string): boolean {
    return this.sameCategoryName(this.categoryRenameSource, category);
  }

  private isFocusedCategory(category: string): boolean {
    const clean = category.trim();
    if (clean.length === 0) {
      return this.selectedCategory.trim().length === 0;
    }
    return this.sameCategoryName(this.selectedCategory, clean);
  }

  private currentFocusedCategory(): string {
    const clean = this.selectedCategory.trim();
    if (clean.length === 0) {
      return '';
    }
    const matched = this.categories.find((category: string) => this.sameCategoryName(category, clean));
    return matched ?? clean;
  }

  private focusCategory(category: string): void {
    const clean = category.trim();
    if (clean.length === 0) {
      this.selectedCategory = '';
      return;
    }
    const matched = this.categories.find((candidate: string) => this.sameCategoryName(candidate, clean));
    this.selectedCategory = matched ?? clean;
  }

  private async onSaveSyncSettings(): Promise<void> {
    try {
      if (
        this.syncProviderType === SyncProviderType.TENCENT_COS ||
        this.syncProviderType === SyncProviderType.ALIYUN_OSS
      ) {
        if (
          this.syncObjectStorageAccessKeyId.trim().length === 0 ||
          this.syncObjectStorageSecretAccessKey.trim().length === 0 ||
          this.syncObjectStorageBucket.trim().length === 0
        ) {
          this.toast('对象存储同步必须填写 AK、SK 和 Bucket');
          return;
        }
      }
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
        objectStorageAccessKeyId: this.syncObjectStorageAccessKeyId.trim(),
        objectStorageSecretAccessKey: this.syncObjectStorageSecretAccessKey,
        objectStorageBucket: this.syncObjectStorageBucket.trim(),
        objectStorageEndpoint: this.syncObjectStorageEndpoint.trim(),
        objectStorageAppId: this.syncObjectStorageAppId.trim(),
        objectStorageCustomUrl: this.syncObjectStorageCustomUrl.trim(),
        objectStorageObjectKey: this.syncObjectStorageObjectKey.trim().length > 0
          ? this.syncObjectStorageObjectKey.trim()
          : 'vault.sync.json',
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
    this.categoryTemplates = this.controller().getCategoryTemplates();
    if (this.selectedEntryId.length > 0 && !this.entries.some((entry: VaultEntry) => entry.id === this.selectedEntryId)) {
      this.selectedEntryId = '';
    }
    if (preserveEntryScroll) {
      setTimeout(() => {
        this.restoreEntryListAnchor(anchorEntryId);
      }, 0);
    }
  }

  private refreshBackups(): void {
    try {
      this.backups = this.controller().listBackups();
    } catch (error) {
      this.backups = [];
      console.error(`Load backups failed: ${error}`);
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
      Row({ space: 8 }) {
        Text(this.categoryDisplayName(this.draftCategory))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_TEXT)
          .height(48)
          .layoutWeight(1)
          .padding({ left: 14, right: 14 })
          .textAlign(TextAlign.Start)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .onClick(() => {
            this.openCategorySelectOverlay();
          });
        Text('选择')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_ACCENT)
          .height(48)
          .padding({ left: 14, right: 14 })
          .textAlign(TextAlign.Center)
          .backgroundColor(UI_SURFACE_ALT)
          .border({ width: 1, color: UI_STROKE })
          .borderRadius(12)
          .onClick(() => {
            this.openCategorySelectOverlay();
          });
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
          .fontColor(UI_TEXT)
          .placeholderColor(UI_MUTED)
          .caretColor(UI_ACCENT)
          .onFocus(() => {
            this.scheduleKeyboardAvoidAreaSync();
          })
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
  private CategoryDraftCustomFieldsEditor() {
    Column({ space: 6 }) {
      Text('自定义字段')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(UI_MUTED);
      if (this.categoryDraftCustomFields.length === 0) {
        Text('字段默认只有名称和备注，可在下方添加自定义字段')
          .fontSize(12)
          .fontColor(UI_MUTED);
      }
      ForEach(this.categoryDraftCustomFields, (field: CustomField) => {
        Column({ space: 8 }) {
          if (this.isCategoryDraftFieldReadOnly(field.id)) {
            Text(field.name.length > 0 ? field.name : '未知字段')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(UI_TEXT)
              .width('100%');
            Text(`字段类型: ${this.categoryDraftFieldValueType(field.id)}`)
              .fontSize(12)
              .fontColor(UI_MUTED)
              .width('100%');
            Text('当前版本无法编辑该字段，原配置已保留。')
              .fontSize(12)
              .fontColor(UI_DANGER)
              .width('100%');
          } else {
            TextInput({ placeholder: '字段名称', text: field.name })
              .width('100%')
              .height(48)
              .backgroundColor(UI_SURFACE_ALT)
              .fontColor(UI_TEXT)
              .placeholderColor(UI_MUTED)
              .caretColor(UI_ACCENT)
              .onFocus(() => {
                this.scheduleKeyboardAvoidAreaSync();
              })
              .border({ width: 1, color: UI_STROKE })
              .borderRadius(12)
              .padding({ left: 14, right: 14 })
              .onChange((value: string) => {
                this.updateCategoryDraftCustomFieldName(field.id, value);
              });
            if (this.isCategoryDraftFieldTypeLocked(field.id)) {
              Text(`字段类型: ${this.categoryDraftFieldValueType(field.id) === 'entryReference' ? '关联条目' : '文本'}`)
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .fontColor(UI_MUTED)
                .width('100%');
              Text('已有条目保存了该字段值，可修改名称和关联范围，但不能删除或更改字段类型。')
                .fontSize(12)
                .fontColor(UI_MUTED)
                .width('100%');
            } else {
              Text('字段类型')
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .fontColor(UI_MUTED)
                .width('100%');
              Flex({ wrap: FlexWrap.Wrap }) {
                this.ChoiceChip('文本', this.categoryDraftFieldValueType(field.id) === 'text', () => {
                  this.updateCategoryDraftFieldType(field.id, 'text');
                });
                this.ChoiceChip(
                  '关联条目',
                  this.categoryDraftFieldValueType(field.id) === 'entryReference',
                  () => {
                    this.updateCategoryDraftFieldType(field.id, 'entryReference');
                  },
                );
              }
            }
            if (this.categoryDraftFieldValueType(field.id) === 'entryReference') {
              this.CategoryDraftTargetCategoryEditor(field);
            }
            if (!this.isCategoryDraftFieldTypeLocked(field.id)) {
              Row({ space: 8 }) {
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
                    this.removeCategoryDraftCustomField(field.id);
                  });
              }
            }
          }
        }
        .padding(10)
        .backgroundColor(UI_SURFACE_ALT)
        .border({ width: 1, color: UI_STROKE })
        .borderRadius(12);
      }, (field: CustomField) => field.id);
      this.AddFieldButton('添加字段', () => {
        this.addCategoryDraftCustomField();
      });
    }
  }

  @Builder
  private CategoryDraftTargetCategoryEditor(field: CustomField) {
    Column({ space: 6 }) {
      Text('目标分类')
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(UI_MUTED)
        .width('100%');
      Text('关联条目只会从所选分类中选择；不限分类会显示全部可用条目。')
        .fontSize(12)
        .fontColor(UI_MUTED)
        .width('100%');
      Flex({ wrap: FlexWrap.Wrap }) {
        this.ChoiceChip('不限分类', field.value.trim().length === 0, () => {
          this.updateCategoryDraftTargetCategory(field.id, '');
        });
        if (this.categoryDraftHasMissingTargetCategory(field)) {
          this.ChoiceChip(`已删除: ${field.value.trim()}`, true, () => {});
        }
        ForEach(this.categories, (category: string) => {
          this.ChoiceChip(category, this.sameCategoryName(field.value, category), () => {
            this.updateCategoryDraftTargetCategory(field.id, category);
          });
        }, (category: string) => category);
      }
    }
    .width('100%');
  }

  @Builder
  private CustomFieldsEditor() {
    Column({ space: 6 }) {
      Text('字段').fontSize(12).fontWeight(FontWeight.Bold).fontColor(UI_MUTED);
      if (this.editableDraftCustomFields().length === 0) {
        Text('字段默认只有名称和备注，可在下方添加自定义字段')
          .fontSize(12)
          .fontColor(UI_MUTED);
      }
      ForEach(this.editableDraftCustomFields(), (field: CustomField) => {
        Column({ space: 8 }) {
          TextInput({ placeholder: '字段名称', text: field.name })
            .width('100%')
            .height(48)
            .backgroundColor(UI_SURFACE_ALT)
            .fontColor(UI_TEXT)
            .placeholderColor(UI_MUTED)
            .caretColor(UI_ACCENT)
            .onFocus(() => {
              this.scheduleKeyboardAvoidAreaSync();
            })
            .border({ width: 1, color: UI_STROKE })
            .borderRadius(12)
            .padding({ left: 14, right: 14 })
            .onChange((value: string) => {
              this.updateDraftCustomFieldName(field.id, value);
            });
          TextInput({ placeholder: '字段值', text: field.value })
            .width('100%')
            .height(48)
            .backgroundColor(UI_SURFACE_ALT)
            .fontColor(UI_TEXT)
            .placeholderColor(UI_MUTED)
            .caretColor(UI_ACCENT)
            .onFocus(() => {
              this.scheduleKeyboardAvoidAreaSync();
            })
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
        .padding(10)
        .backgroundColor(UI_SURFACE_ALT)
        .border({ width: 1, color: UI_STROKE })
        .borderRadius(12);
      }, (field: CustomField) => field.id);
      this.AddFieldButton('添加字段', () => {
        this.addDraftCustomField();
      });
    }
  }

  @Builder
  private AddFieldButton(label: string, action: () => void) {
    Row({ space: 8 }) {
      Text('+')
        .width(28)
        .height(28)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(UI_ACCENT)
        .textAlign(TextAlign.Center)
        .backgroundColor(UI_SELECTED)
        .borderRadius(8);
      Text(label)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(UI_ACCENT);
    }
    .height(44)
    .width('100%')
    .padding({ left: 12, right: 12 })
    .backgroundColor(UI_SURFACE_ALT)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(12)
    .onClick(action);
  }

  @Builder
  private EntryReferenceFieldsEditor() {
    if (this.editableDraftReferenceFields().length > 0) {
      Column({ space: 6 }) {
        Text('关联字段')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_MUTED)
          .width('100%');
        ForEach(this.editableDraftReferenceFields(), (field: CustomField) => {
          this.EntryReferenceFieldEditor(field);
        }, (field: CustomField) => field.id);
      }
      .width('100%');
    }
  }

  @Builder
  private EntryReferenceFieldEditor(field: CustomField) {
    Column({ space: 8 }) {
      Text(field.name.length > 0 ? field.name : '关联字段')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(UI_TEXT)
        .width('100%');
      Text(this.entryReferenceDraftDisplayValue(field))
        .fontSize(13)
        .fontColor(this.entryReferenceDraftStatusColor(field))
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
      Text(this.entryReferenceDraftConstraintText(field))
        .fontSize(12)
        .fontColor(UI_MUTED)
        .width('100%');
      Row({ space: 8 }) {
        Column() {
          this.PrimaryTextButton(this.entryReferenceDraftActionLabel(field), () => {
            this.openEntryReferenceSelectOverlay(field.id);
          });
        }
        .layoutWeight(1);
        if (field.value.length > 0) {
          Column() {
            this.SecondaryTextButton('清除关联', () => {
              this.updateDraftCustomFieldValue(field.id, '');
            });
          }
          .layoutWeight(1);
        }
      }
      .width('100%');
    }
    .width('100%')
    .padding(10)
    .backgroundColor(UI_SURFACE_ALT)
    .border({ width: 1, color: UI_STROKE })
    .borderRadius(12);
  }

  @Builder
  private UnsupportedDraftFieldsNotice() {
    if (this.unsupportedDraftCustomFields().length > 0) {
      Column({ space: 4 }) {
        Text(`另有 ${this.unsupportedDraftCustomFields().length} 个当前版本不支持的字段`)
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(UI_DANGER)
          .width('100%');
        Text('这些字段不会显示原值，也不会被修改或删除；保存时会原样保留。')
          .fontSize(12)
          .fontColor(UI_MUTED)
          .width('100%');
      }
      .width('100%')
      .padding(10)
      .backgroundColor(UI_DANGER_SURFACE)
      .border({ width: 1, color: UI_DANGER })
      .borderRadius(12);
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
    this.syncObjectStorageAccessKeyId = settings.objectStorageAccessKeyId;
    this.syncObjectStorageSecretAccessKey = settings.objectStorageSecretAccessKey;
    this.syncObjectStorageBucket = settings.objectStorageBucket;
    this.syncObjectStorageEndpoint = settings.objectStorageEndpoint;
    this.syncObjectStorageAppId = settings.objectStorageAppId;
    this.syncObjectStorageCustomUrl = settings.objectStorageCustomUrl;
    this.syncObjectStorageObjectKey = settings.objectStorageObjectKey;
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

  private openTopOverlay(panel: TopOverlayPanel): void {
    if (this.topOverlayPanel === panel) {
      this.closeTopOverlay();
      return;
    }
    if (this.topOverlayPanel === 'entryEditor') {
      this.clearEntryDraft();
    }
    if (panel === 'create') {
      this.categoryRenameSource = '';
    }
    if (panel === 'backup') {
      this.refreshBackups();
    }
    this.topOverlayPanel = panel;
  }

  private closeTopOverlay(): void {
    if (this.topOverlayPanel === 'none' && this.entryEditorVisible) {
      this.clearEntryDraft();
      this.entryEditorVisible = false;
      return;
    }
    if (this.topOverlayPanel === 'entryEditor') {
      this.clearEntryDraft();
      this.entryEditorVisible = false;
    }
    if (this.topOverlayPanel === 'entryReferenceSelect') {
      this.restoreEntryEditorOverlay();
      return;
    }
    if ((this.topOverlayPanel === 'categorySelect' || this.topOverlayPanel === 'categoryCreate') &&
      (this.categorySelectReturnToEntry || this.categoryCreateReturnToEntry)) {
      this.restoreEntryEditorOverlay();
      return;
    }
    this.categorySelectReturnToEntry = false;
    this.categoryCreateReturnToEntry = false;
    this.topOverlayPanel = 'none';
  }

  private restoreEntryEditorOverlay(): void {
    this.categorySelectReturnToEntry = false;
    this.categoryCreateReturnToEntry = false;
    this.categoryRenameSource = '';
    this.categoryDraft = '';
    this.categoryDraftCustomFields = [];
    this.categoryDraftFieldTypes = [];
    this.draftReferenceFieldId = '';
    this.draftReferenceSearch = '';
    this.entryEditorVisible = false;
    this.activePanel = 'home';
    this.topOverlayPanel = 'entryEditor';
  }

  private openMainPanel(panel: ActivePanel): void {
    this.activePanel = panel;
    this.entryEditorVisible = false;
    this.exportEntryId = '';
    this.closeTopOverlay();
  }

  private prepareCreateCategoryOverlay(initialValue: string, returnToEntry: boolean = false): void {
    this.categoryDraft = initialValue;
    this.categoryCreateReturnToEntry = returnToEntry;
    this.categorySelectReturnToEntry = false;
    this.categoryRenameSource = '';
    this.categoryDraftCustomFields = [];
    this.categoryDraftFieldTypes = [];
    this.topOverlayPanel = 'categoryCreate';
  }

  private prepareCreateTagOverlay(initialValue: string): void {
    this.tagDraft = initialValue;
    this.topOverlayPanel = 'tagCreate';
  }

  private openCategorySelectOverlay(): void {
    this.draftCategorySearch = '';
    this.categorySelectReturnToEntry = this.topOverlayPanel === 'entryEditor';
    this.topOverlayPanel = 'categorySelect';
  }

  private openEntryReferenceSelectOverlay(fieldId: string): void {
    const field = this.draftCustomFields.find(
      (candidate: CustomField) => candidate.id === fieldId,
    );
    if (field === undefined || !this.isEditableDraftReferenceField(field)) {
      return;
    }
    this.draftReferenceFieldId = fieldId;
    this.draftReferenceSearch = '';
    this.topOverlayPanel = 'entryReferenceSelect';
  }

  private openEntryDetailOverlay(entry: VaultEntry): void {
    this.selectedEntryId = entry.id;
    this.exportEntryId = '';
    this.topOverlayPanel = 'entryDetail';
  }

  private activeDraftReferenceField(): CustomField | null {
    if (this.draftReferenceFieldId.length === 0) {
      return null;
    }
    const field = this.draftCustomFields.find(
      (candidate: CustomField) => candidate.id === this.draftReferenceFieldId,
    );
    return field === undefined ? null : field;
  }

  private activeDraftReferenceTemplate(): FieldTemplate | null {
    const field = this.activeDraftReferenceField();
    if (field === null) {
      return null;
    }
    const definition = this.templateDefinitionForCustomField(field, this.draftCategory);
    return definition !== undefined && this.isEntryReferenceTemplateField(definition)
      ? definition
      : null;
  }

  private activeDraftReferenceValue(): string {
    return this.activeDraftReferenceField()?.value ?? '';
  }

  private filteredEntryReferenceCandidates(): EntryReferenceCandidate[] {
    const template = this.activeDraftReferenceTemplate();
    if (template === null) {
      return [];
    }
    return entryReferenceCandidates(
      this.entries,
      typeof template.targetCategory === 'string' ? template.targetCategory : '',
      this.draftReferenceSearch,
    );
  }

  private entryReferenceSelectorTitle(): string {
    const field = this.activeDraftReferenceField();
    return field === null || field.name.trim().length === 0
      ? '选择关联条目'
      : `选择“${field.name.trim()}”`;
  }

  private entryReferenceSelectorHint(): string {
    const template = this.activeDraftReferenceTemplate();
    const category = template?.targetCategory?.trim() ?? '';
    return category.length > 0
      ? `仅显示“${category}”分类中的可用条目。`
      : '显示全部分类中的可用条目。';
  }

  private entryReferenceSelectorEmptyText(): string {
    const template = this.activeDraftReferenceTemplate();
    const category = template?.targetCategory?.trim() ?? '';
    return category.length > 0
      ? `“${category}”分类暂无可关联条目`
      : '暂无可关联条目';
  }

  private selectActiveDraftReference(entryId: string): void {
    const field = this.activeDraftReferenceField();
    if (field === null) {
      return;
    }
    this.updateDraftCustomFieldValue(field.id, entryId);
    this.restoreEntryEditorOverlay();
  }

  private clearActiveDraftReference(): void {
    const field = this.activeDraftReferenceField();
    if (field === null) {
      return;
    }
    this.updateDraftCustomFieldValue(field.id, '');
    this.restoreEntryEditorOverlay();
  }

  private openClearDataOverlay(): void {
    this.clearDataPassword = '';
    this.topOverlayPanel = 'clearData';
  }

  private updateViewportSize(area: Area): void {
    const previousWidth = this.viewportWidth;
    const width = this.lengthToNumber(area.width);
    const height = this.lengthToNumber(area.height);
    this.viewportWidth = width;
    this.viewportHeight = height;
    if (this.shouldUpdateKeyboardBaselineViewportHeight(width, height, previousWidth)) {
      this.keyboardBaselineViewportHeight = height;
    }
    if (this.appWindow !== null && this.inputFloatingPanelActive()) {
      this.syncKeyboardAvoidArea(this.appWindow);
    }
  }

  private shouldUpdateKeyboardBaselineViewportHeight(width: number, height: number, previousWidth: number): boolean {
    if (height <= 0) {
      return false;
    }
    if (this.keyboardBaselineViewportHeight <= 0 || height > this.keyboardBaselineViewportHeight) {
      return true;
    }
    if (this.keyboardHeight > 0) {
      return false;
    }
    const widthChanged = previousWidth > 0 && Math.abs(width - previousWidth) > VIEWPORT_WIDTH_RESIZE_TOLERANCE;
    if (widthChanged) {
      return true;
    }
    return this.keyboardBaselineViewportHeight - height <= KEYBOARD_BASELINE_DROP_GUARD;
  }

  private async bindKeyboardAvoidance(context: Context): Promise<void> {
    try {
      this.unbindKeyboardAvoidance();
      const currentWindow = await window.getLastWindow(context);
      this.appWindow = currentWindow;
      currentWindow.on('keyboardHeightChange', this.keyboardHeightChangeHandler);
      this.syncKeyboardAvoidArea(currentWindow);
    } catch (error) {
      console.error(`Keyboard avoidance unavailable: ${error}`);
    }
  }

  private unbindKeyboardAvoidance(): void {
    if (this.appWindow !== null) {
      try {
        this.appWindow.off('keyboardHeightChange', this.keyboardHeightChangeHandler);
      } catch (error) {
        console.error(`Keyboard avoidance cleanup failed: ${error}`);
      }
    }
    this.appWindow = null;
    this.keyboardHeight = 0;
  }

  private syncKeyboardAvoidArea(currentWindow: window.Window): void {
    try {
      const avoidArea = currentWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_KEYBOARD);
      const keyboardHeight = Math.max(0, avoidArea.bottomRect.height);
      this.keyboardHeight = avoidArea.visible || keyboardHeight > 0 ? keyboardHeight : 0;
    } catch (error) {
      console.error(`Keyboard avoid area unavailable: ${error}`);
    }
  }

  private scheduleKeyboardAvoidAreaSync(): void {
    if (this.appWindow === null) {
      return;
    }
    setTimeout(() => {
      if (this.appWindow !== null) {
        this.syncKeyboardAvoidArea(this.appWindow);
      }
    }, 80);
  }

  private lengthToNumber(value: Length): number {
    if (typeof value === 'number') {
      return value;
    }
    const parsed = Number.parseFloat(`${value}`);
    return Number.isFinite(parsed) ? parsed : 0;
  }

  private useWideLayout(): boolean {
    const width = this.viewportWidth > 0 ? this.viewportWidth : 0;
    return width >= WIDE_LAYOUT_MIN_WIDTH || this.hasExpandedFoldPosture();
  }

  private useExpandedLayout(): boolean {
    const width = this.viewportWidth > 0 ? this.viewportWidth : 0;
    return width >= EXPANDED_LAYOUT_MIN_WIDTH || this.hasExpandedFoldPosture();
  }

  private hasExpandedFoldPosture(): boolean {
    return this.foldableDevice && (
      this.currentFoldStatus === display.FoldStatus.FOLD_STATUS_EXPANDED ||
      this.currentFoldStatus === display.FoldStatus.FOLD_STATUS_EXPANDED_WITH_SECOND_EXPANDED ||
      this.currentFoldStatus === display.FoldStatus.FOLD_STATUS_EXPANDED_WITH_SECOND_HALF_FOLDED
    );
  }

  private floatingPanelWidth(): string | number {
    const width = this.viewportWidth;
    if (width <= 0) {
      return 320;
    }
    if (width < 420) {
      return Math.max(width - 16, 240);
    }
    if (width < WIDE_LAYOUT_MIN_WIDTH) {
      return Math.max(width - 32, 320);
    }
    if (this.topOverlayPanel === 'entryEditor') {
      return this.useExpandedLayout() ? 620 : 560;
    }
    if (this.topOverlayPanel === 'settings') {
      return 520;
    }
    if (this.topOverlayPanel === 'backup') {
      return 420;
    }
    return 360;
  }

  private floatingPanelWidthValue(): number {
    const value = this.floatingPanelWidth();
    return typeof value === 'number' ? value : 360;
  }

  private floatingPanelX(): number {
    const width = this.viewportWidth > 0 ? this.viewportWidth : this.floatingPanelWidthValue() + 16;
    return Math.max(width - this.floatingPanelWidthValue() - 8, 8);
  }

  private floatingPanelUsesAvailableHeight(): boolean {
    return this.topOverlayPanel === 'entryEditor' ||
      this.topOverlayPanel === 'entryReferenceSelect' ||
      this.topOverlayPanel === 'entryDetail' ||
      this.topOverlayPanel === 'categoryCreate' ||
      this.topOverlayPanel === 'settings';
  }

  private inputFloatingPanelActive(): boolean {
    return this.floatingPanelUsesAvailableHeight();
  }

  private viewportCompressedByKeyboard(): boolean {
    if (!this.inputFloatingPanelActive() || this.keyboardBaselineViewportHeight <= 0 || this.viewportHeight <= 0) {
      return false;
    }
    return this.keyboardBaselineViewportHeight - this.viewportHeight > KEYBOARD_BASELINE_DROP_GUARD;
  }

  private floatingPanelKeyboardMode(): boolean {
    return this.keyboardVisible() || this.viewportCompressedByKeyboard();
  }

  private floatingPanelY(): number {
    if (this.floatingPanelKeyboardMode()) {
      return 8;
    }
    if (this.viewportHeight > 0 && this.viewportHeight < 560) {
      return 12;
    }
    return 56;
  }

  private floatingPanelBottomGap(): number {
    return this.floatingPanelKeyboardMode() ? 8 : 32;
  }

  private keyboardVisible(): boolean {
    return this.keyboardHeight > 0;
  }

  private effectiveKeyboardInset(): number {
    if (!this.floatingPanelKeyboardMode()) {
      return 0;
    }
    if (this.keyboardHeight > 0) {
      if (this.viewportAlreadyAvoidsKeyboard()) {
        if (!this.floatingPanelUsesKeyboardBaselineHeight()) {
          return 0;
        }
      }
    }
    const height = this.floatingPanelLayoutHeight();
    return Math.min(this.remainingKeyboardOverlap(), Math.max(height - 220, 0));
  }

  private viewportAlreadyAvoidsKeyboard(): boolean {
    if (this.keyboardHeight <= 0 || this.keyboardBaselineViewportHeight <= 0 || this.viewportHeight <= 0) {
      return false;
    }
    return this.keyboardHeight - this.viewportKeyboardShrink() <= KEYBOARD_INSET_TOLERANCE;
  }

  private remainingKeyboardOverlap(): number {
    if (this.keyboardHeight <= 0) {
      return this.viewportKeyboardShrink();
    }
    if (this.floatingPanelUsesKeyboardBaselineHeight()) {
      return this.keyboardHeight;
    }
    return Math.max(this.keyboardHeight - this.viewportKeyboardShrink(), 0);
  }

  private viewportKeyboardShrink(): number {
    if (this.keyboardBaselineViewportHeight <= 0 || this.viewportHeight <= 0) {
      return 0;
    }
    return Math.max(this.keyboardBaselineViewportHeight - this.viewportHeight, 0);
  }

  private floatingPanelUsesKeyboardBaselineHeight(): boolean {
    const height = this.viewportHeight > 0 ? this.viewportHeight : 0;
    return this.floatingPanelKeyboardMode() &&
      this.keyboardBaselineViewportHeight > 0 &&
      this.keyboardBaselineViewportHeight > height;
  }

  private floatingPanelLayoutHeight(): number {
    const height = this.viewportHeight > 0 ? this.viewportHeight : 720;
    if (this.floatingPanelUsesKeyboardBaselineHeight()) {
      return this.keyboardBaselineViewportHeight;
    }
    return height;
  }

  private floatingPanelMaxHeight(): number {
    const height = this.floatingPanelLayoutHeight();
    const availableHeight =
      height - this.floatingPanelY() - this.floatingPanelBottomGap() - this.effectiveKeyboardInset();
    return Math.max(availableHeight, this.floatingPanelKeyboardMode() ? 140 : 320);
  }

  private settingsPanelScrollHeight(): number {
    return Math.max(this.floatingPanelMaxHeight() - 58, this.floatingPanelKeyboardMode() ? 96 : 220);
  }

  private backupListHeight(): number {
    return Math.max(Math.min(this.floatingPanelMaxHeight() - 156, 380), 96);
  }

  private categorySelectListHeight(): number {
    return Math.max(Math.min(this.floatingPanelMaxHeight() - 126, 360), 96);
  }

  private entryReferenceSelectListHeight(): number {
    return Math.max(this.floatingPanelMaxHeight() - 190, 96);
  }

  private categoryCreatePanelScrollHeight(): number {
    return Math.max(this.floatingPanelMaxHeight() - 58, this.floatingPanelKeyboardMode() ? 120 : 260);
  }

  private entryEditorPanelScrollHeight(): number {
    return Math.max(this.floatingPanelMaxHeight() - 58, this.floatingPanelKeyboardMode() ? 120 : 260);
  }

  private categoryDisplayName(category: string): string {
    return category.trim().length > 0 ? category : '未分类';
  }

  private toolbarIconSize(): number {
    const width = this.viewportWidth;
    if (this.headerToolbarCompact()) {
      return 36;
    }
    if (width > 0 && width < 420) {
      return 38;
    }
    return 44;
  }

  private toolbarIconFontSize(icon: string): number {
    return icon === '···' ? 13 : 21;
  }

  private toolbarActionsMinWidth(): number {
    return (this.toolbarIconSize() + 2) * 5;
  }

  private headerToolbarCompact(): boolean {
    const width = this.viewportWidth;
    return width > 0 && width < 820;
  }

  private headerTitleFontSize(): number {
    return this.headerToolbarCompact() ? 17 : 20;
  }

  private showHeaderSubtitle(): boolean {
    if (this.useWideLayout() && this.activePanel === 'home' && !this.entryEditorVisible) {
      return !this.headerToolbarCompact();
    }
    return this.viewportWidth <= 0 || this.viewportWidth >= 420;
  }

  private primaryPaneMinWidth(): number {
    return 320;
  }

  private primaryPaneMaxWidth(): number {
    return this.useExpandedLayout() ? 560 : 430;
  }

  private primaryPaneWidth(): string | number {
    return this.useExpandedLayout() ? '42%' : '46%';
  }

  private formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }

  private formatBackupTime(timestamp: number): string {
    if (timestamp <= 0) {
      return '-';
    }
    return new Date(timestamp).toLocaleString();
  }

  private configureFoldableState(): void {
    this.updateFoldableState();
    try {
      display.on('foldStatusChange', this.foldStatusChangeHandler);
    } catch (error) {
      console.info(`Fold status listener unavailable: ${error}`);
    }
  }

  private stopFoldableState(): void {
    try {
      display.off('foldStatusChange', this.foldStatusChangeHandler);
    } catch (error) {
      console.info(`Fold status listener cleanup skipped: ${error}`);
    }
  }

  private updateFoldableState(): void {
    try {
      this.foldableDevice = display.isFoldable();
      this.currentFoldStatus = this.foldableDevice ? display.getFoldStatus() : 0;
    } catch (error) {
      this.foldableDevice = false;
      this.currentFoldStatus = 0;
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
      return this.categories;
    }
    return this.categories
      .filter((category: string) => category.toLowerCase().includes(query));
  }

  private showUncategorizedDraftCategory(): boolean {
    const query = this.draftCategorySearch.trim().toLowerCase();
    return query.length === 0 || '未分类'.toLowerCase().includes(query);
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
    await this.controller().addCategoryWithTemplateFields(
      category,
      this.categoryDraftTemplateFieldDefinitions(),
    );
    this.categoryDraftCustomFields = [];
    this.categoryDraftFieldTypes = [];
    this.refreshData();
    this.selectDraftCategory(category);
  }

  private selectDraftCategory(category: string): void {
    if (this.sameCategoryName(category, this.draftCategory)) {
      this.draftCategorySearch = '';
      return;
    }
    this.protectDraftFieldsBeforeCategorySwitch();
    this.draftCategory = category;
    this.draftCategorySearch = '';
    this.categoryDraftCustomFields = [];
    this.categoryDraftFieldTypes = [];
    this.applyCategoryTemplateToDraft(category);
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

  private applyCategoryTemplateToDraft(category: string): void {
    const usedExistingIndexes = new Set<number>();
    const seen = new Set<string>();
    const nextFields: CustomField[] = [];
    const nextFieldCategories: DraftCustomFieldCategoryState[] = [];
    this.templateFieldsForCategory(category).forEach((templateField: FieldTemplate) => {
      if (!this.isTextTemplateField(templateField)) {
        if (!this.isEntryReferenceTemplateField(templateField)) {
          return;
        }
      }
      const name = templateField.name.trim();
      const key = name.toLowerCase();
      if (name.length === 0 || key === '名称' || seen.has(key)) {
        return;
      }
      seen.add(key);
      let existingIndex = -1;
      if (templateField.id.length > 0) {
        existingIndex = this.draftCustomFields.findIndex(
          (field: CustomField, index: number) =>
            !usedExistingIndexes.has(index) &&
            field.templateFieldId === templateField.id &&
            (
              !this.draftProtectedCustomFieldIds.includes(field.id) ||
              this.draftFieldBelongsToCategory(field.id, category)
            ),
        );
        if (existingIndex >= 0) {
          const matchedId = this.draftCustomFields[existingIndex].id;
          this.draftProtectedCustomFieldIds = this.draftProtectedCustomFieldIds.filter(
            (id: string) => id !== matchedId,
          );
        }
      }
      if (existingIndex < 0) {
        existingIndex = this.draftCustomFields.findIndex(
          (field: CustomField, index: number) =>
            !usedExistingIndexes.has(index) &&
            !this.draftProtectedCustomFieldIds.includes(field.id) &&
            field.name.trim().toLowerCase() === key,
        );
      }
      const existing = existingIndex >= 0 ? this.draftCustomFields[existingIndex] : undefined;
      if (existingIndex >= 0) {
        usedExistingIndexes.add(existingIndex);
      }
      const nextField: CustomField = {
        id: existing !== undefined && existing.id.length > 0 ? existing.id : this.nextUiId(),
        templateFieldId: existing !== undefined &&
          typeof existing.templateFieldId === 'string' && existing.templateFieldId.length > 0
          ? existing.templateFieldId
          : templateField.id,
        name: name,
        value: existing?.value ?? '',
      };
      nextFields.push(nextField);
      nextFieldCategories.push({ fieldId: nextField.id, category });
    });
    this.draftCustomFields.forEach((field: CustomField, index: number) => {
      if (usedExistingIndexes.has(index)) {
        return;
      }
      const nextField: CustomField = {
        id: field.id.length > 0 ? field.id : this.nextUiId(),
        templateFieldId: field.templateFieldId,
        name: field.name,
        value: field.value,
      };
      nextFields.push(nextField);
      const existingCategory = this.draftCustomFieldCategories.find(
        (state: DraftCustomFieldCategoryState) => state.fieldId === field.id,
      );
      if (existingCategory !== undefined) {
        nextFieldCategories.push({
          fieldId: nextField.id,
          category: existingCategory.category,
        });
      }
    });
    this.draftCustomFields = nextFields;
    this.draftCustomFieldCategories = nextFieldCategories;
  }

  private clearEntryDraft(): void {
    this.draftLabel = '';
    this.draftCategory = '';
    this.draftCategorySearch = '';
    this.draftTagSearch = '';
    this.draftSelectedTags = [];
    this.draftCustomFields = [];
    this.draftProtectedCustomFieldIds = [];
    this.draftCustomFieldCategories = [];
    this.draftReferenceFieldId = '';
    this.draftReferenceSearch = '';
    this.editingEntryId = '';
  }

  private beginCreateEntry(): void {
    this.clearEntryDraft();
    this.draftCategory = this.currentFocusedCategory();
    this.applyCategoryTemplateToDraft(this.draftCategory);
    this.activePanel = 'home';
    this.selectedEntryId = '';
    this.entryEditorVisible = false;
    this.topOverlayPanel = 'entryEditor';
  }

  private startEditEntry(entry: VaultEntry): void {
    this.clearEntryDraft();
    this.activePanel = 'home';
    this.entryEditorVisible = false;
    this.topOverlayPanel = 'entryEditor';
    this.editingEntryId = entry.id;
    this.selectedEntryId = entry.id;
    this.exportEntryId = '';
    this.draftLabel = entry.label;
    this.draftCategory = this.entryCategory(entry);
    this.draftSelectedTags = [...entry.tags];
    this.draftCustomFields = this.copyCustomFields(entry.customFields);
    this.draftCustomFieldCategories = this.draftCustomFields.map((field: CustomField) => {
      const state: DraftCustomFieldCategoryState = {
        fieldId: field.id,
        category: this.draftCategory,
      };
      return state;
    });
    this.draftProtectedCustomFieldIds = this.protectedCustomFieldIdsForCategory(
      this.draftCustomFields,
      this.draftCategory,
    );
    this.draftType = this.draftTypeFromEntry(entry);
    this.applyCategoryTemplateToDraft(this.draftCategory);
  }

  private draftTypeFromEntry(entry: VaultEntry): DraftType {
    if (entry.type === VaultEntryType.SERVER) {
      return 'server';
    }
    if (entry.type === VaultEntryType.SERVICE) {
      return 'service';
    }
    return 'credential';
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
        templateFieldId: field.templateFieldId,
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
        templateFieldId: field.templateFieldId,
        name: field.name,
        value: value,
      };
    });
  }

  private removeDraftCustomField(id: string): void {
    this.draftCustomFields = this.draftCustomFields.filter((field: CustomField) => field.id !== id);
    this.draftProtectedCustomFieldIds = this.draftProtectedCustomFieldIds.filter(
      (fieldId: string) => fieldId !== id,
    );
    this.draftCustomFieldCategories = this.draftCustomFieldCategories.filter(
      (state: DraftCustomFieldCategoryState) => state.fieldId !== id,
    );
  }

  private addCategoryDraftCustomField(): void {
    const field: CustomField = {
      id: this.nextUiId(),
      name: '',
      value: '',
    };
    this.categoryDraftCustomFields = [...this.categoryDraftCustomFields, field];
    this.categoryDraftFieldTypes = [
      ...this.categoryDraftFieldTypes,
      { fieldId: field.id, valueType: 'text', readOnly: false, typeLocked: false },
    ];
  }

  private addCategoryDraftShortcutFields(preset: CategoryTypePreset): void {
    const existing = new Set<string>();
    this.categoryDraftCustomFields.forEach((field: CustomField) => {
      const key = field.name.trim().toLowerCase();
      if (key.length > 0) {
        existing.add(key);
      }
    });
    this.categoryPresetFieldNames(preset).forEach((name: string) => {
      const key = name.trim().toLowerCase();
      if (key.length === 0 || existing.has(key)) {
        return;
      }
      existing.add(key);
      const field: CustomField = {
        id: this.nextUiId(),
        name: name,
        value: '',
      };
      this.categoryDraftCustomFields = [...this.categoryDraftCustomFields, field];
      this.categoryDraftFieldTypes = [
        ...this.categoryDraftFieldTypes,
        { fieldId: field.id, valueType: 'text', readOnly: false, typeLocked: false },
      ];
    });
  }

  private updateCategoryDraftCustomFieldName(id: string, value: string): void {
    this.categoryDraftCustomFields = this.categoryDraftCustomFields.map((field: CustomField) => {
      if (field.id !== id) {
        return field;
      }
      return {
        id: field.id,
        templateFieldId: field.templateFieldId,
        name: value,
        value: field.value,
      };
    });
  }

  private removeCategoryDraftCustomField(id: string): void {
    if (this.isCategoryDraftFieldTypeLocked(id)) {
      return;
    }
    this.categoryDraftCustomFields =
      this.categoryDraftCustomFields.filter((field: CustomField) => field.id !== id);
    this.categoryDraftFieldTypes = this.categoryDraftFieldTypes.filter(
      (field: CategoryFieldTypeState) => field.fieldId !== id,
    );
  }

  private categoryDraftTemplateFieldDefinitions(): FieldTemplate[] {
    return this.categoryDraftCustomFields
      .filter((field: CustomField) => field.name.trim().length > 0)
      .map((field: CustomField) => {
        const valueType = this.categoryDraftFieldValueType(field.id);
        const definition: FieldTemplate = {
          id: typeof field.templateFieldId === 'string' && field.templateFieldId.length > 0
            ? field.templateFieldId
            : field.id,
          name: field.name.trim(),
          valueType,
          targetCategory: valueType === 'entryReference' ? field.value.trim() : '',
        };
        return definition;
      });
  }

  private categoryDraftFieldValueType(fieldId: string): string {
    const state = this.categoryDraftFieldTypes.find(
      (field: CategoryFieldTypeState) => field.fieldId === fieldId,
    );
    return state === undefined ? 'text' : state.valueType;
  }

  private isCategoryDraftFieldReadOnly(fieldId: string): boolean {
    const state = this.categoryDraftFieldTypes.find(
      (field: CategoryFieldTypeState) => field.fieldId === fieldId,
    );
    return state?.readOnly === true;
  }

  private isCategoryDraftFieldTypeLocked(fieldId: string): boolean {
    const state = this.categoryDraftFieldTypes.find(
      (field: CategoryFieldTypeState) => field.fieldId === fieldId,
    );
    return state?.typeLocked === true;
  }

  private updateCategoryDraftFieldType(fieldId: string, valueType: string): void {
    if (
      this.isCategoryDraftFieldReadOnly(fieldId) ||
      this.isCategoryDraftFieldTypeLocked(fieldId)
    ) {
      return;
    }
    this.categoryDraftFieldTypes = this.categoryDraftFieldTypes.map(
      (field: CategoryFieldTypeState) => {
        if (field.fieldId !== fieldId) {
          return field;
        }
        return {
          fieldId: field.fieldId,
          valueType,
          readOnly: false,
          typeLocked: field.typeLocked,
        };
      },
    );
    if (valueType === 'text') {
      this.updateCategoryDraftTargetCategory(fieldId, '');
    }
  }

  private updateCategoryDraftTargetCategory(fieldId: string, category: string): void {
    this.categoryDraftCustomFields = this.categoryDraftCustomFields.map((field: CustomField) => {
      if (field.id !== fieldId) {
        return field;
      }
      return {
        id: field.id,
        templateFieldId: field.templateFieldId,
        name: field.name,
        value: category,
      };
    });
  }

  private categoryDraftHasMissingTargetCategory(field: CustomField): boolean {
    const target = field.value.trim();
    return target.length > 0 && !this.categories.some(
      (category: string) => this.sameCategoryName(category, target),
    );
  }

  private normalizedDraftCustomFields(): CustomField[] {
    return this.draftCustomFields
      .map((field: CustomField) => {
        const normalized: CustomField = {
          id: field.id.length > 0 ? field.id : this.nextUiId(),
          templateFieldId: field.templateFieldId,
          name: this.isEditableDraftCustomField(field) ? field.name.trim() : field.name,
          value: field.value,
        };
        return normalized;
      })
      .filter((field: CustomField) =>
        field.name.length > 0 ||
        field.value.trim().length > 0 ||
        (typeof field.templateFieldId === 'string' && field.templateFieldId.length > 0)
      );
  }

  private copyCustomFields(fields: CustomField[]): CustomField[] {
    return fields.map((field: CustomField) => {
      const copy: CustomField = {
        id: field.id.length > 0 ? field.id : this.nextUiId(),
        templateFieldId: field.templateFieldId,
        name: field.name,
        value: field.value,
      };
      return copy;
    });
  }

  private editableDraftCustomFields(): CustomField[] {
    return this.draftCustomFields.filter((field: CustomField) =>
      this.isEditableDraftCustomField(field)
    );
  }

  private editableDraftReferenceFields(): CustomField[] {
    return this.draftCustomFields.filter((field: CustomField) =>
      this.isEditableDraftReferenceField(field)
    );
  }

  private isEditableDraftReferenceField(field: CustomField): boolean {
    if (this.draftProtectedCustomFieldIds.includes(field.id)) {
      return false;
    }
    const definition = this.templateDefinitionForCustomField(field, this.draftCategory);
    return definition !== undefined && this.isEntryReferenceTemplateField(definition);
  }

  private unsupportedDraftCustomFields(): CustomField[] {
    return this.draftCustomFields.filter((field: CustomField) => {
      if (this.draftProtectedCustomFieldIds.includes(field.id)) {
        return true;
      }
      const definition = this.templateDefinitionForCustomField(field, this.draftCategory);
      if (definition === undefined) {
        return this.hasTemplateFieldBinding(field);
      }
      return !isEditableCategoryFieldType(this.templateFieldValueType(definition));
    });
  }

  private entryReferenceDraftResolution(field: CustomField): EntryReferenceResolution | null {
    return this.controller().resolveEntryReferenceField(field, this.draftCategory);
  }

  private entryReferenceDraftDisplayValue(field: CustomField): string {
    const resolution = this.entryReferenceDraftResolution(field);
    if (resolution === null || resolution.status === EntryReferenceStatus.EMPTY) {
      return '未选择关联条目';
    }
    if (resolution.status === EntryReferenceStatus.MISSING) {
      return '关联条目不存在';
    }
    if (resolution.status === EntryReferenceStatus.DELETED) {
      return resolution.target === undefined
        ? '关联条目已删除'
        : `${resolution.target.label} · 已删除`;
    }
    if (resolution.status === EntryReferenceStatus.CATEGORY_MISMATCH) {
      return resolution.target === undefined
        ? '关联条目分类不匹配'
        : `${resolution.target.label} · 当前分类: ${resolution.target.category || '未分类'}`;
    }
    return resolution.target === undefined
      ? '关联条目不存在'
      : `${resolution.target.label} · ${resolution.target.category || '未分类'}`;
  }

  private entryReferenceDraftStatusColor(field: CustomField): Resource {
    const resolution = this.entryReferenceDraftResolution(field);
    if (
      resolution === null ||
      resolution.status === EntryReferenceStatus.EMPTY ||
      resolution.status === EntryReferenceStatus.RESOLVED
    ) {
      return resolution?.status === EntryReferenceStatus.RESOLVED ? UI_TEXT : UI_MUTED;
    }
    return UI_DANGER;
  }

  private entryReferenceDraftConstraintText(field: CustomField): string {
    const definition = this.templateDefinitionForCustomField(field, this.draftCategory);
    const targetCategory = definition?.targetCategory?.trim() ?? '';
    return targetCategory.length > 0
      ? `目标分类: ${targetCategory}`
      : '目标分类: 不限分类';
  }

  private entryReferenceDraftActionLabel(field: CustomField): string {
    const resolution = this.entryReferenceDraftResolution(field);
    if (resolution === null || resolution.status === EntryReferenceStatus.EMPTY) {
      return '选择';
    }
    if (resolution.status === EntryReferenceStatus.RESOLVED) {
      return '更换';
    }
    return '重新选择';
  }

  private isEditableDraftCustomField(field: CustomField): boolean {
    if (this.draftProtectedCustomFieldIds.includes(field.id)) {
      return false;
    }
    return canExposeRawCustomFieldValue(
      field,
      this.categoryTemplate(this.draftCategory),
    );
  }

  private protectedCustomFieldIdsForCategory(fields: CustomField[], category: string): string[] {
    return fields
      .filter((field: CustomField) => {
        const definition = this.templateDefinitionForCustomField(field, category);
        if (definition === undefined) {
          return this.hasTemplateFieldBinding(field);
        }
        return !isEditableCategoryFieldType(this.templateFieldValueType(definition));
      })
      .map((field: CustomField) => field.id);
  }

  private protectDraftFieldsBeforeCategorySwitch(): void {
    const protectedIds = new Set<string>(this.draftProtectedCustomFieldIds);
    this.draftCustomFields.forEach((field: CustomField) => {
      const definition = this.templateDefinitionForCustomField(field, this.draftCategory);
      if (
        (definition === undefined && this.hasTemplateFieldBinding(field)) ||
        (definition !== undefined && !this.isTextTemplateField(definition))
      ) {
        protectedIds.add(field.id);
      }
    });
    this.draftProtectedCustomFieldIds = Array.from(protectedIds.values());
  }

  private draftFieldBelongsToCategory(fieldId: string, category: string): boolean {
    const state = this.draftCustomFieldCategories.find(
      (candidate: DraftCustomFieldCategoryState) => candidate.fieldId === fieldId,
    );
    return state !== undefined && this.sameCategoryName(state.category, category);
  }

  private templateDefinitionForCustomField(
    field: CustomField,
    category: string,
  ): FieldTemplate | undefined {
    const templateFields = this.templateFieldsForCategory(category);
    if (typeof field.templateFieldId === 'string' && field.templateFieldId.length > 0) {
      return templateFields.find(
        (templateField: FieldTemplate) => templateField.id === field.templateFieldId,
      );
    }
    const name = field.name.trim().toLowerCase();
    if (name.length === 0) {
      return undefined;
    }
    return templateFields.find(
      (templateField: FieldTemplate) => templateField.name.trim().toLowerCase() === name,
    );
  }

  private isEntryReferenceCustomField(entry: VaultEntry, field: CustomField): boolean {
    const definition = this.templateDefinitionForCustomField(field, this.entryCategory(entry));
    return definition !== undefined && this.isEntryReferenceTemplateField(definition);
  }

  private isUnsupportedCustomField(entry: VaultEntry, field: CustomField): boolean {
    return !canExposeRawCustomFieldValue(
      field,
      this.categoryTemplate(this.entryCategory(entry)),
    );
  }

  private hasTemplateFieldBinding(field: CustomField): boolean {
    return typeof field.templateFieldId === 'string' && field.templateFieldId.length > 0;
  }

  private entryReferenceDetailResolution(
    entry: VaultEntry,
    field: CustomField,
  ): EntryReferenceResolution | null {
    return this.controller().resolveEntryReferenceField(field, this.entryCategory(entry));
  }

  private entryReferenceDetailText(entry: VaultEntry, field: CustomField): string {
    const resolution = this.entryReferenceDetailResolution(entry, field);
    if (resolution === null || resolution.status === EntryReferenceStatus.EMPTY) {
      return '未选择关联条目';
    }
    if (resolution.status === EntryReferenceStatus.MISSING) {
      return '关联条目不存在';
    }
    if (resolution.status === EntryReferenceStatus.DELETED) {
      return resolution.target === undefined
        ? '关联条目已删除'
        : `${resolution.target.label} · 已删除`;
    }
    if (resolution.status === EntryReferenceStatus.CATEGORY_MISMATCH) {
      const definition = this.templateDefinitionForCustomField(field, this.entryCategory(entry));
      const requiredCategory = definition?.targetCategory?.trim() ?? '';
      if (resolution.target === undefined) {
        return requiredCategory.length > 0
          ? `关联条目已不在“${requiredCategory}”分类`
          : '关联条目分类不匹配';
      }
      return requiredCategory.length > 0
        ? `${resolution.target.label} · 当前: ${resolution.target.category || '未分类'} · 要求: ${requiredCategory}`
        : `${resolution.target.label} · 分类不匹配`;
    }
    return resolution.target === undefined
      ? '关联条目不存在'
      : `${resolution.target.label} · ${resolution.target.category || '未分类'}`;
  }

  private entryReferenceDetailColor(entry: VaultEntry, field: CustomField): Resource {
    const resolution = this.entryReferenceDetailResolution(entry, field);
    if (
      resolution === null ||
      resolution.status === EntryReferenceStatus.EMPTY
    ) {
      return UI_MUTED;
    }
    return resolution.status === EntryReferenceStatus.RESOLVED ? UI_TEXT : UI_DANGER;
  }

  private entryReferenceRepairLabel(entry: VaultEntry, field: CustomField): string {
    const resolution = this.entryReferenceDetailResolution(entry, field);
    if (resolution === null || resolution.status === EntryReferenceStatus.EMPTY) {
      return '选择关联';
    }
    if (resolution.status === EntryReferenceStatus.RESOLVED) {
      return '更换关联';
    }
    return '修复关联';
  }

  private entryReferenceTargetCanOpen(entry: VaultEntry, field: CustomField): boolean {
    const resolution = this.entryReferenceDetailResolution(entry, field);
    if (resolution === null || resolution.target === undefined) {
      return false;
    }
    return resolution.status !== EntryReferenceStatus.DELETED &&
      resolution.status !== EntryReferenceStatus.MISSING;
  }

  private openEntryReferenceTarget(entry: VaultEntry, field: CustomField): void {
    const target = this.entryReferenceDetailResolution(entry, field)?.target;
    if (target === undefined) {
      return;
    }
    this.searchQuery = '';
    this.selectedTag = '';
    this.focusCategory(target.category);
    this.selectedEntryId = target.id;
    if (this.topOverlayPanel === 'entryDetail') {
      this.topOverlayPanel = 'none';
    }
    setTimeout(() => {
      const targetIndex = this.filteredEntries().findIndex(
        (candidate: VaultEntry) => candidate.id === target.id,
      );
      if (targetIndex >= 0) {
        this.entryListFirstVisibleIndex = targetIndex;
        this.entryListScroller.scrollToIndex(targetIndex);
      }
    }, 0);
  }

  private repairEntryReference(entry: VaultEntry, field: CustomField): void {
    this.startEditEntry(entry);
    this.openEntryReferenceSelectOverlay(field.id);
  }

  private prepareClearEntryReference(entry: VaultEntry, field: CustomField): void {
    this.startEditEntry(entry);
    this.updateDraftCustomFieldValue(field.id, '');
    this.toast('关联已清除，保存后生效');
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
      { id: 'label', label: '名称' },
      { id: 'category', label: '分类' },
      { id: 'tags', label: '标签' },
      { id: 'createdAt', label: '创建时间' },
      { id: 'updatedAt', label: '更新时间' },
    ];
    entry.customFields.forEach((field: CustomField) => {
      options.push({
        id: `custom.${field.id}`,
        label: field.name.length > 0 ? field.name : '自定义字段',
      });
    });
    return options;
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
    this.closeTopOverlay();
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
    return util.generateRandomUUID().toLowerCase();
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
        this.safeCustomFieldSearchValues(entry, customField).forEach(
          (value: string) => values.push(value),
        );
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
        this.safeCustomFieldSearchValues(entry, customField).forEach(
          (value: string) => values.push(value),
        );
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
        this.safeCustomFieldSearchValues(entry, customField).forEach(
          (value: string) => values.push(value),
        );
      }
    });
    return values;
  }

  private safeCustomFieldSearchValues(entry: VaultEntry, field: CustomField): string[] {
    return referenceSafeCustomFieldSearchValues(
      field,
      this.categoryTemplate(this.entryCategory(entry)),
      this.entries,
    );
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
      this.FilterPill('未分类', selectedCategory.trim().length === 0, () => {
        onSelected('');
      });
      ForEach(this.categories, (category: string) => {
        this.FilterPill(category, this.sameCategoryName(selectedCategory, category), () => {
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
    this.focusCategory(clean);
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
    const filledFields = entry.customFields
      .map((field: CustomField) => this.entrySummaryField(entry, field))
      .filter((value: string) => value.length > 0)
      .slice(0, 3)
      .map((value: string) => value);
    if (filledFields.length > 0) {
      return filledFields.join('  ');
    }
    const templateFields = entry.customFields
      .filter((field: CustomField) => field.name.trim().length > 0)
      .slice(0, 3)
      .map((field: CustomField) => field.name.trim());
    return templateFields.length > 0 ? `字段: ${templateFields.join('、')}` : '暂无字段数据';
  }

  private entrySummaryField(entry: VaultEntry, field: CustomField): string {
    const name = field.name.trim().length > 0 ? field.name.trim() : '字段';
    if (this.isEntryReferenceCustomField(entry, field)) {
      const resolution = this.entryReferenceDetailResolution(entry, field);
      if (resolution === null || resolution.status === EntryReferenceStatus.EMPTY) {
        return `${name}: 未关联`;
      }
      if (resolution.status === EntryReferenceStatus.RESOLVED && resolution.target !== undefined) {
        return `${name}: ${resolution.target.label}`;
      }
      return `${name}: 关联失效`;
    }
    if (this.isUnsupportedCustomField(entry, field)) {
      return `${name}: 不支持的字段`;
    }
    return field.value.trim().length > 0 ? `${name}: ${field.value}` : '';
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
