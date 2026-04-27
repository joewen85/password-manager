import { Context } from '@kit.AbilityKit';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
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
import {
  ImportConflictStrategy,
  ImportPreviewRecord,
  VaultController,
} from '../src/service/VaultController';
import { VaultCryptoService } from '../src/security/VaultCryptoService';
import { InMemoryVaultStore, PreferencesVaultStore } from '../src/storage/VaultStore';
import { ConflictStrategy, SyncProviderType, SyncSettings } from '../src/sync/SyncTypes';

type DraftType = 'credential' | 'server' | 'service';
const MAX_UNLOCK_ATTEMPTS: number = 5;

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
}

interface EntryCategoryCarrier {
  category?: string;
  metadataCategory?: string;
}

@Entry
@Component
struct Index {
  private vaultController: VaultController | null = null;
  private hostContext: Context | null = null;

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
  @State private toastMessage: string = '';
  @State private toastVersion: number = 0;

  @State private searchQuery: string = '';
  @State private selectedCategory: string = '';
  @State private selectedTag: string = '';

  @State private entries: VaultEntry[] = [];
  @State private tags: string[] = [];
  @State private categories: string[] = [];

  @State private tagDraft: string = '';
  @State private categoryDraft: string = '';
  @State private categoryRenameSource: string = '';

  @State private draftType: DraftType = 'credential';
  @State private draftLabel: string = '';
  @State private draftCategory: string = '';
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
      this.hostContext = hostContext;
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
    .backgroundColor('#F4F6F0');
  }

  @Builder
  private ToastBanner() {
    Text(this.toastMessage)
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .margin({ bottom: 12 })
      .backgroundColor('#1F4E46')
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
      this.CategorySection();
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
      Button('导入条目')
        .type(ButtonType.Normal)
        .margin({ right: 8 })
        .onClick(() => {
          this.onImportEntry();
        });
      Button('导出数据')
        .type(ButtonType.Normal)
        .margin({ right: 8 })
        .onClick(() => {
          this.onExportVault();
        });
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
      if (this.categories.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          this.FilterPill('全部分类', this.selectedCategory.length === 0, () => {
            this.selectedCategory = '';
          });
          ForEach(this.categories, (category: string) => {
            this.FilterPill(category, this.selectedCategory === category, () => {
              this.selectedCategory = this.selectedCategory === category ? '' : category;
            });
          }, (category: string) => category);
        }
      }

      TextInput({ placeholder: '字段搜索按当前分类，tag:/# 标签全局', text: $$this.searchQuery })
        .width('100%')
        .height(44)
        .backgroundColor('#FFFFFF')
        .borderRadius(12)
        .padding({ left: 12, right: 12 });
      Text('字段搜索遵循当前分类筛选；仅 tag:/# 搜索可跨分类全局匹配标签')
        .fontSize(12)
        .fontColor('#5A6668');

      if (this.tags.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          this.FilterPill('全部标签', this.selectedTag.length === 0, () => {
            this.selectedTag = '';
          });
          ForEach(this.tags, (tag: string) => {
            this.FilterPill(tag, this.selectedTag === tag, () => {
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
  private NewEntrySection() {
    Column({ space: 8 }) {
      Text('新建条目').fontSize(18).fontWeight(FontWeight.Medium);
      Text('条目类型').fontSize(12).fontColor('#5A6668');

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

      TextInput({ placeholder: '分类（可选）', text: $$this.draftCategory })
        .width('100%')
        .height(42)
        .backgroundColor('#FFFFFF')
        .borderRadius(10)
        .padding({ left: 10, right: 10 });

      if (this.categories.length > 0) {
        Text('可直接输入新分类，或点选已有分类')
          .fontSize(12)
          .fontColor('#5A6668');
        this.CategoryDraftPills(this.draftCategory.trim(), (category: string) => {
          this.draftCategory = category;
        });
      }

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
            .backgroundColor('#FFFFFF')
            .borderRadius(999)
            .onClick(() => {});
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
  private CategorySection() {
    Column({ space: 8 }) {
      Row() {
        Text('分类管理').fontSize(18).fontWeight(FontWeight.Medium);
        Blank();
        Button('导入分类')
          .type(ButtonType.Normal)
          .onClick(() => {
            this.onImportCategory();
          });
      }

      Row({ space: 8 }) {
        TextInput({ placeholder: '新增分类', text: $$this.categoryDraft })
          .layoutWeight(1)
          .height(42)
          .backgroundColor('#FFFFFF')
          .borderRadius(10)
          .padding({ left: 10, right: 10 });
        Button('添加').onClick(() => this.onAddCategory());
        Button(this.categoryRenameSource.length > 0 ? '保存重命名' : '重命名')
          .onClick(() => this.onRenameCategory());
      }

      if (this.categoryRenameSource.length > 0) {
        Row({ space: 8 }) {
          Text(`当前重命名: ${this.categoryRenameSource}`)
            .fontSize(12)
            .fontColor('#5A6668');
          Text('取消')
            .fontSize(12)
            .fontColor('#2F7F79')
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
              Button('x')
                .fontSize(11)
                .width(22)
                .height(22)
                .onClick(() => {
                  this.onDeleteCategory(category);
                });
            }
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .margin({ right: 6, bottom: 6 })
            .backgroundColor(this.categoryRenameSource === category ? '#BEE6D6' : '#FFFFFF')
            .borderRadius(999)
            .onClick(() => {
              this.categoryRenameSource = category;
              this.categoryDraft = category;
            });
          }, (category: string) => category);
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

      if (this.hasActiveFilters()) {
        this.ActiveFilterSummary(this.filteredEntries().length);
      }

      List({ space: 8 }) {
        ForEach(this.filteredEntries(), (entry: VaultEntry) => {
          ListItem() {
            Column({ space: 6 }) {
              Row() {
                Text(entry.label)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor(this.entryTitleMatched(entry) ? '#0F4C5C' : '#1F2B2D');
                Blank();
                Text(this.typeLabel(entry.type)).fontSize(12).fontColor('#2F7F79');
              }

              Text(this.entrySummary(entry))
                .fontSize(12)
                .fontColor(this.entrySummaryMatched(entry) ? '#0F4C5C' : '#5C6769')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
              Text(`分类: ${this.entryCategory(entry) || '-'}`)
                .fontSize(11)
                .fontColor(this.entryCategoryMatched(entry) ? '#0F4C5C' : '#6D787A')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis });

              if (entry.tags.length > 0) {
                this.EntryTagPills(entry);
              } else {
                Text('标签: -').fontSize(11).fontColor('#6D787A');
              }

              if (this.entryMatchLabels(entry).length > 0) {
                this.EntryMatchPills(entry);
              }

              Row() {
                Text(new Date(entry.updatedAt).toLocaleString()).fontSize(11).fontColor('#7A8587');
                Blank();
                Button('导出')
                  .type(ButtonType.Normal)
                  .margin({ right: 8 })
                  .backgroundColor('#D7EAF3')
                  .fontColor('#1F4E6B')
                  .onClick(() => {
                    this.onExportEntry(entry);
                  });
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

  @Builder
  private EntryTagPills(entry: VaultEntry) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(entry.tags, (tag: string) => {
        Text(tag)
          .fontSize(11)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .margin({ right: 6, bottom: 4 })
          .backgroundColor(this.tagMatched(tag) ? '#BEE6D6' : '#EEF3F1')
          .fontColor(this.tagMatched(tag) ? '#0F4C5C' : '#5E6A6C')
          .borderRadius(999);
      }, (tag: string, index: number) => `${tag}-${index}`);
    }
  }

  @Builder
  private EntryMatchPills(entry: VaultEntry) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.entryMatchLabels(entry), (label: string) => {
        Text(label)
          .fontSize(11)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .margin({ right: 6, bottom: 4 })
          .backgroundColor('#0F4C5C')
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
          .backgroundColor(label.startsWith('结果:') ? '#BEE6D6' : '#FFFFFF')
          .fontColor(label.startsWith('结果:') ? '#0F4C5C' : '#5E6A6C')
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
    this.schedulePostUnlockRefresh();
  }

  private async onCreateEntry(): Promise<void> {
    const label = this.draftLabel.trim();
    if (label.length === 0) {
      this.toast('标题必填');
      return;
    }

    const tags = this.parseTags(this.draftTags);
    const category = this.draftCategory.trim();

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
        category: category
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
        tags: tags,
        category: category
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
        tags: tags,
        category: category
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

  private async onExportEntry(entry: VaultEntry): Promise<void> {
    try {
      const data = this.controller().exportEntryData(entry.id);
      const filePath = await this.saveJsonExportFile('entry-export', entry.label, data);
      this.toast(`条目已导出到 ${filePath}`);
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
    this.categories = this.controller().getCategories();
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
          { text: '继续', color: '#0F4C5C', primary: true },
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
          { text: '保留副本', color: '#0F4C5C' },
          { text: '覆盖现有', color: '#0F4C5C' },
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
    this.draftCategory = '';
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
        const prefix = part.substring(0, splitIndex).toLowerCase();
        const value = part.substring(splitIndex + 1).trim().toLowerCase();
        if (value.length === 0) {
          return;
        }
        if (prefix === 'title' || prefix === 'name' || prefix === 'label') {
          terms.push({ field: 'title', value: value });
          return;
        }
        if (prefix === 'service' || prefix === 'svc') {
          terms.push({ field: 'service', value: value });
          return;
        }
        if (prefix === 'app' || prefix === 'appid') {
          terms.push({ field: 'app', value: value });
          return;
        }
        if (prefix === 'server' || prefix === 'srv') {
          terms.push({ field: 'server', value: value });
          return;
        }
        if (prefix === 'ip') {
          terms.push({ field: 'ip', value: value });
          return;
        }
        if (prefix === 'tag' || prefix === 'tags') {
          terms.push({ field: 'tag', value: value });
          return;
        }
      }
      terms.push({ field: 'any', value: part.toLowerCase() });
    });
    return terms;
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
    return this.textContainsTerms(entry.label, ['any', 'title', 'service', 'server', 'app', 'ip']);
  }

  private entrySummaryMatched(entry: VaultEntry): boolean {
    return this.textContainsTerms(this.entrySummary(entry), ['any', 'service', 'server', 'app', 'ip']);
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
    return this.textContainsTerms(category, ['any', 'title']);
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
    const labelLower = entry.label.toLowerCase();
    const categoryLower = this.entryCategory(entry).toLowerCase();
    const payload = entry.payload as SearchPayload;
    const payloadName = (payload.name ?? '').toLowerCase();
    const appId = (payload.appId ?? '').toLowerCase();
    const ipAddress = (payload.ipAddress ?? '').toLowerCase();
    const anyParts: string[] = [labelLower, categoryLower, appId, payloadName, ipAddress];
    entry.tags.forEach((tag: string) => anyParts.push(tag.toLowerCase()));
    const anyLower = anyParts.join('\n');
    return terms.every((term: SearchTerm) => {
      if (term.field === 'title') {
        return labelLower.includes(term.value);
      }
      if (term.field === 'service') {
        return entry.type === VaultEntryType.SERVICE &&
          (labelLower.includes(term.value) || payloadName.includes(term.value));
      }
      if (term.field === 'app') {
        return appId.includes(term.value);
      }
      if (term.field === 'server') {
        return (entry.type === VaultEntryType.SERVER && labelLower.includes(term.value)) ||
          payloadName.includes(term.value);
      }
      if (term.field === 'ip') {
        return ipAddress.includes(term.value);
      }
      if (term.field === 'tag') {
        return entry.tags.some((entryTag: string) => entryTag.toLowerCase().includes(term.value));
      }
      return anyLower.includes(term.value);
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
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .margin({ right: 6, bottom: 6 })
      .backgroundColor(selected ? '#BEE6D6' : '#FFFFFF')
      .borderRadius(999)
      .onClick(action);
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
