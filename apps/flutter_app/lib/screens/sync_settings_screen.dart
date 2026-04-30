import 'package:flutter/material.dart';

import '../state/sync_settings.dart';
import '../state/vault_controller.dart';

class SyncSettingsScreen extends StatefulWidget {
  const SyncSettingsScreen({super.key, required this.controller});

  final VaultController controller;

  @override
  State<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends State<SyncSettingsScreen> {
  final _formKey = GlobalKey<FormState>();

  late SyncProviderType _providerType;
  late ConflictStrategy _conflictStrategy;
  late bool _autoSyncEnabled;
  late bool _autoSyncOnUnlock;
  late bool _syncMasterKey;
  final _intervalController = TextEditingController();

  final _webdavUrlController = TextEditingController();
  final _webdavUsernameController = TextEditingController();
  final _webdavPasswordController = TextEditingController();
  final _webdavPathController = TextEditingController();

  final _presignedDownloadController = TextEditingController();
  final _presignedUploadController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final settings = widget.controller.syncSettings;
    _providerType = settings.providerType;
    _conflictStrategy = settings.conflictStrategy;
    _autoSyncEnabled = settings.autoSyncEnabled;
    _autoSyncOnUnlock = settings.autoSyncOnUnlock;
    _syncMasterKey = settings.syncMasterKey;
    _intervalController.text = settings.autoSyncIntervalMinutes.toString();
    _webdavUrlController.text = settings.webdavUrl;
    _webdavUsernameController.text = settings.webdavUsername;
    _webdavPasswordController.text = settings.webdavPassword;
    _webdavPathController.text = settings.webdavPath;
    _presignedDownloadController.text = settings.presignedDownloadUrl;
    _presignedUploadController.text = settings.presignedUploadUrl;
  }

  @override
  void dispose() {
    _intervalController.dispose();
    _webdavUrlController.dispose();
    _webdavUsernameController.dispose();
    _webdavPasswordController.dispose();
    _webdavPathController.dispose();
    _presignedDownloadController.dispose();
    _presignedUploadController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.controller.syncSettings;
    return Scaffold(
      appBar: AppBar(
        title: const Text('同步设置'),
        actions: [
          IconButton(
            tooltip: '立即同步',
            icon: widget.controller.isSyncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            onPressed: widget.controller.isSyncing
                ? null
                : () async {
                    await widget.controller.syncNow(notifyProgress: true);
                    if (!context.mounted) {
                      return;
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('同步完成')),
                    );
                  },
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle('同步方式'),
                    DropdownButtonFormField<SyncProviderType>(
                      initialValue: _providerType,
                      items: const [
                        DropdownMenuItem(
                          value: SyncProviderType.none,
                          child: Text('不启用'),
                        ),
                        DropdownMenuItem(
                          value: SyncProviderType.webdav,
                          child: Text('WebDAV（云盘）'),
                        ),
                        DropdownMenuItem(
                          value: SyncProviderType.nasWebdav,
                          child: Text('NAS（WebDAV）'),
                        ),
                        DropdownMenuItem(
                          value: SyncProviderType.s3Presigned,
                          child: Text('S3 预签名 URL'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() => _providerType = value);
                      },
                    ),
                    const SizedBox(height: 16),
                    if (_providerType == SyncProviderType.webdav ||
                        _providerType == SyncProviderType.nasWebdav)
                      _webdavFields(),
                    if (_providerType == SyncProviderType.s3Presigned)
                      _presignedFields(),
                    const SizedBox(height: 16),
                    _sectionTitle('自动同步'),
                    SwitchListTile(
                      title: const Text('启用自动同步'),
                      value: _autoSyncEnabled,
                      onChanged: (value) {
                        setState(() => _autoSyncEnabled = value);
                      },
                    ),
                    TextFormField(
                      controller: _intervalController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '同步间隔（分钟）',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return '必填';
                        }
                        final parsed = int.tryParse(value);
                        if (parsed == null || parsed <= 0) {
                          return '请输入大于 0 的整数';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      title: const Text('解锁后立即同步'),
                      value: _autoSyncOnUnlock,
                      onChanged: (value) {
                        setState(() => _autoSyncOnUnlock = value);
                      },
                    ),
                    const SizedBox(height: 16),
                    _sectionTitle('冲突策略'),
                    DropdownButtonFormField<ConflictStrategy>(
                      initialValue: _conflictStrategy,
                      items: const [
                        DropdownMenuItem(
                          value: ConflictStrategy.remoteWins,
                          child: Text('以远端为准'),
                        ),
                        DropdownMenuItem(
                          value: ConflictStrategy.localWins,
                          child: Text('以本地为准'),
                        ),
                        DropdownMenuItem(
                          value: ConflictStrategy.keepBoth,
                          child: Text('保留两个副本'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() => _conflictStrategy = value);
                      },
                    ),
                    const SizedBox(height: 16),
                    _sectionTitle('加密与密钥'),
                    SwitchListTile(
                      title: const Text('同步主密钥参数（推荐）'),
                      subtitle: const Text('用于在其他设备验证主密码'),
                      value: _syncMasterKey,
                      onChanged: (value) {
                        setState(() => _syncMasterKey = value);
                      },
                    ),
                    const SizedBox(height: 16),
                    _sectionTitle('同步状态'),
                    _statusRow('上次同步时间',
                        settings.lastSyncAt?.toLocal().toString() ?? '无'),
                    _statusRow('状态', settings.lastSyncStatus ?? '无'),
                    _statusRow('说明', settings.lastSyncMessage ?? '无'),
                    _statusRow(
                      '设备ID',
                      settings.deviceId.isEmpty ? '未生成' : settings.deviceId,
                    ),
                    _statusRow('修订号', settings.lastSyncRevision.toString()),
                    const SizedBox(height: 8),
                    if (settings.logs.isNotEmpty) _logsSection(settings.logs),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _saveSettings,
                        child: const Text('保存设置'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _webdavFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: _webdavUrlController,
          decoration: const InputDecoration(
            labelText: 'WebDAV 地址',
            border: OutlineInputBorder(),
          ),
          validator: (value) {
            if (_providerType == SyncProviderType.webdav ||
                _providerType == SyncProviderType.nasWebdav) {
              if (value == null || value.trim().isEmpty) {
                return '必填';
              }
            }
            return null;
          },
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _webdavPathController,
          decoration: const InputDecoration(
            labelText: '远端路径',
            helperText: '例如 /backup/password_manager/vault.json',
            border: OutlineInputBorder(),
          ),
          validator: (value) {
            if (_providerType == SyncProviderType.webdav ||
                _providerType == SyncProviderType.nasWebdav) {
              if (value == null || value.trim().isEmpty) {
                return '必填';
              }
            }
            return null;
          },
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _webdavUsernameController,
          decoration: const InputDecoration(
            labelText: '用户名',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _webdavPasswordController,
          decoration: const InputDecoration(
            labelText: '密码',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
        ),
      ],
    );
  }

  Widget _presignedFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          controller: _presignedDownloadController,
          decoration: const InputDecoration(
            labelText: '下载 URL（GET）',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _presignedUploadController,
          decoration: const InputDecoration(
            labelText: '上传 URL（PUT）',
            border: OutlineInputBorder(),
          ),
          validator: (value) {
            if (_providerType == SyncProviderType.s3Presigned) {
              if (value == null || value.trim().isEmpty) {
                return '必填';
              }
            }
            return null;
          },
        ),
      ],
    );
  }

  Widget _statusRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 120, child: Text(label)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _logsSection(List<SyncLogEntry> logs) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '同步日志',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        ...logs.map(
          (entry) => Text(
            '[${entry.timestamp.toLocal()}] ${entry.message}',
            style: TextStyle(
              color: entry.level == 'error'
                  ? colorScheme.error
                  : colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _saveSettings() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final interval = int.tryParse(_intervalController.text.trim()) ?? 30;
    var webdavPath = _webdavPathController.text.trim();
    if (_providerType == SyncProviderType.webdav ||
        _providerType == SyncProviderType.nasWebdav) {
      if (webdavPath.isEmpty) {
        webdavPath = '/vault.json';
      }
      if (!webdavPath.startsWith('/')) {
        webdavPath = '/$webdavPath';
      }
      if (webdavPath.endsWith('/')) {
        webdavPath = '${webdavPath}vault.json';
      }
    }
    final settings = SyncSettings(
      providerType: _providerType,
      webdavUrl: _webdavUrlController.text.trim(),
      webdavUsername: _webdavUsernameController.text.trim(),
      webdavPassword: _webdavPasswordController.text.trim(),
      webdavPath: webdavPath,
      presignedDownloadUrl: _presignedDownloadController.text.trim(),
      presignedUploadUrl: _presignedUploadController.text.trim(),
      autoSyncEnabled: _autoSyncEnabled,
      autoSyncIntervalMinutes: interval,
      autoSyncOnUnlock: _autoSyncOnUnlock,
      conflictStrategy: _conflictStrategy,
      syncMasterKey: _syncMasterKey,
      deviceId: widget.controller.syncSettings.deviceId,
      lastSyncRevision: widget.controller.syncSettings.lastSyncRevision,
      lastSyncAt: widget.controller.syncSettings.lastSyncAt,
      lastSyncStatus: widget.controller.syncSettings.lastSyncStatus,
      lastSyncMessage: widget.controller.syncSettings.lastSyncMessage,
      logs: widget.controller.syncSettings.logs,
    );
    await widget.controller.updateSyncSettings(settings);
    if (_providerType == SyncProviderType.webdav ||
        _providerType == SyncProviderType.nasWebdav) {
      _webdavPathController.text = webdavPath;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存设置')),
      );
    }
  }
}
