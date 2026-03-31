import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:password_manager_core/password_manager_core.dart';

import '../state/vault_controller.dart';
import 'export_file.dart';

Future<void> presentJsonExport(
  BuildContext context, {
  required String title,
  required String filename,
  required String contents,
  bool allowCopyContents = false,
}) async {
  if (!supportsLocalTextFileIO) {
    if (allowCopyContents) {
      final action = await _promptSimpleExportAction(
        context,
        title: title,
        suggestedFilename: filename,
      );
      if (action == null) {
        return;
      }
      if (action == _JsonExportAction.copyContents) {
        await Clipboard.setData(ClipboardData(text: contents));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已复制 JSON 内容')),
          );
        }
        return;
      }
    }

    await downloadTextFile(
      filename: filename,
      contents: contents,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('导出完成')),
      );
    }
    return;
  }

  final exportDestination = await _promptJsonExportDestination(
    context,
    title: title,
    suggestedFilename: filename,
    allowCopyContents: allowCopyContents,
  );
  if (exportDestination == null) {
    return;
  }
  if (exportDestination.action == _JsonExportAction.copyContents) {
    await Clipboard.setData(ClipboardData(text: contents));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制 JSON 内容')),
      );
    }
    return;
  }

  final savedFile = await saveTextFile(
    filename: filename,
    contents: contents,
    filePath: exportDestination.path,
  );
  if (!context.mounted) {
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('$title已保存'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              exportDestination.path.trim().isEmpty
                  ? '文件已保存到所选位置：'
                  : '文件已保存到自定义位置：',
            ),
            const SizedBox(height: 12),
            SelectableText(savedFile.path),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: savedFile.path));
            if (dialogContext.mounted) {
              Navigator.of(dialogContext).pop();
            }
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制文件路径')),
              );
            }
          },
          child: const Text('复制路径'),
        ),
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: contents));
            if (dialogContext.mounted) {
              Navigator.of(dialogContext).pop();
            }
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制 JSON 内容')),
              );
            }
          },
          child: const Text('复制内容'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

Future<_JsonExportDestination?> _promptJsonExportDestination(
  BuildContext context, {
  required String title,
  required String suggestedFilename,
  required bool allowCopyContents,
}) async {
  final pathController = TextEditingController();
  return showDialog<_JsonExportDestination>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('可自定义导出文件保存位置。'),
              const SizedBox(height: 12),
              SelectableText('建议文件名: $suggestedFilename'),
              const SizedBox(height: 12),
              TextField(
                controller: pathController,
                decoration: const InputDecoration(
                  labelText: '保存路径（可选）',
                  hintText: '/path/to/export.json 或 /path/to/folder/',
                  border: OutlineInputBorder(),
                  helperText: '留空则打开系统“另存为”窗口；填写时会直接保存到该位置。',
                ),
              ),
              if (supportsSystemFilePicker) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final selectedPath = await pickSaveFilePath(
                        suggestedName: suggestedFilename,
                      );
                      if (selectedPath == null) {
                        return;
                      }
                      setState(() => pathController.text = selectedPath);
                    },
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text('系统选择位置'),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          if (allowCopyContents)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                const _JsonExportDestination(
                  action: _JsonExportAction.copyContents,
                ),
              ),
              child: const Text('复制内容'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(
              _JsonExportDestination(
                path: pathController.text.trim(),
                action: _JsonExportAction.saveFile,
              ),
            ),
            child: const Text('导出'),
          ),
        ],
      ),
    ),
  );
}

Future<_JsonExportAction?> _promptSimpleExportAction(
  BuildContext context, {
  required String title,
  required String suggestedFilename,
}) async {
  return showDialog<_JsonExportAction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('可直接下载文件，或仅复制 JSON 内容。'),
            const SizedBox(height: 12),
            SelectableText('建议文件名: $suggestedFilename'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(_JsonExportAction.copyContents),
          child: const Text('复制内容'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(_JsonExportAction.saveFile),
          child: const Text('导出'),
        ),
      ],
    ),
  );
}

Future<String?> promptJsonImport(
  BuildContext context, {
  required String title,
  String? hintText,
  String? helperText,
}) async {
  final textController = TextEditingController();
  final pathController = TextEditingController();
  PickedTextFile? pickedFile;
  final source = await showDialog<_JsonImportSource>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (helperText != null && helperText.trim().isNotEmpty) ...[
                Text(helperText),
                const SizedBox(height: 12),
              ],
              if (supportsSystemFilePicker) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        pickedFile == null
                            ? '未选择文件'
                            : '已选择：${pickedFile!.path ?? pickedFile!.name}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: () async {
                        final result = await pickTextFile();
                        if (result == null) {
                          return;
                        }
                        setState(() {
                          pickedFile = result;
                          pathController.text = result.path ?? result.name;
                        });
                      },
                      child: const Text('选择文件'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              if (supportsLocalTextFileIO) ...[
                TextField(
                  controller: pathController,
                  decoration: const InputDecoration(
                    labelText: '本地 JSON 文件路径',
                    hintText: '/path/to/file.json',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('或直接粘贴 JSON：'),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: textController,
                maxLines: 16,
                minLines: 10,
                decoration: InputDecoration(
                  hintText: hintText ?? '请粘贴 JSON',
                  alignLabelWithHint: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(
              _JsonImportSource(
                path: pathController.text,
                contents: pickedFile?.contents ?? textController.text,
              ),
            ),
            child: const Text('导入'),
          ),
        ],
      ),
    ),
  );
  if (source == null) {
    return null;
  }
  final path = source.path.trim();
  if (supportsLocalTextFileIO && path.isNotEmpty) {
    return readTextFile(path: path);
  }
  return source.contents;
}

String buildJsonExportFilename({
  required String scope,
  String? name,
}) {
  final normalizedName = (name ?? '')
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
      .replaceAll(RegExp(r'\s+'), '_');
  final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
  final prefix = normalizedName.isEmpty ? scope : '$scope-$normalizedName';
  return '$prefix-$timestamp.json';
}

class _JsonImportSource {
  const _JsonImportSource({
    required this.path,
    required this.contents,
  });

  final String path;
  final String contents;
}

class _JsonExportDestination {
  const _JsonExportDestination({
    this.path = '',
    required this.action,
  });

  final String path;
  final _JsonExportAction action;
}

enum _JsonExportAction { saveFile, copyContents }

Future<ImportConflictStrategy?> showImportPreviewDialog(
  BuildContext context, {
  required ImportPreview preview,
}) async {
  var selectedStrategy = ImportConflictStrategy.keepCopy;
  return showDialog<ImportConflictStrategy>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) => AlertDialog(
        title: Text(preview.scope == ImportScope.item ? '导入条目预览' : '导入分类预览'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '共 ${preview.totalCount} 条：新增 ${preview.createCount}，重复 ${preview.exactDuplicateCount}，冲突 ${preview.conflictCount}',
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: ListView(
                    shrinkWrap: true,
                    children: preview.items
                        .take(8)
                        .map(
                          (item) => ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(item.label),
                            subtitle: Text(
                              '${_typeLabel(item.type)} · ${item.category.isEmpty ? "未分类" : item.category} · ${_dispositionLabel(item.disposition)}'
                              '${item.existingLabel == null ? "" : "（本地: ${item.existingLabel}）"}',
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
              ),
              if (preview.items.length > 8)
                Text('其余 ${preview.items.length - 8} 条未展开显示'),
              if (preview.hasConflicts) ...[
                const SizedBox(height: 12),
                const Text('冲突处理策略'),
                RadioListTile<ImportConflictStrategy>(
                  value: ImportConflictStrategy.keepCopy,
                  groupValue: selectedStrategy,
                  title: const Text('保留副本'),
                  subtitle: const Text('不覆盖现有条目，导入为新条目'),
                  onChanged: (value) =>
                      setState(() => selectedStrategy = value!),
                ),
                RadioListTile<ImportConflictStrategy>(
                  value: ImportConflictStrategy.overwrite,
                  groupValue: selectedStrategy,
                  title: const Text('覆盖现有'),
                  subtitle: const Text('用导入内容更新匹配到的现有条目'),
                  onChanged: (value) =>
                      setState(() => selectedStrategy = value!),
                ),
                RadioListTile<ImportConflictStrategy>(
                  value: ImportConflictStrategy.skip,
                  groupValue: selectedStrategy,
                  title: const Text('跳过冲突'),
                  subtitle: const Text('重复和冲突条目均跳过，仅导入新增'),
                  onChanged: (value) =>
                      setState(() => selectedStrategy = value!),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(selectedStrategy),
            child: const Text('开始导入'),
          ),
        ],
      ),
    ),
  );
}

String _typeLabel(VaultEntryType type) {
  switch (type) {
    case VaultEntryType.credential:
      return '账号';
    case VaultEntryType.server:
      return '服务器';
    case VaultEntryType.service:
      return '服务';
  }
}

String _dispositionLabel(ImportItemDisposition disposition) {
  switch (disposition) {
    case ImportItemDisposition.create:
      return '新增';
    case ImportItemDisposition.exactDuplicate:
      return '重复';
    case ImportItemDisposition.conflict:
      return '冲突';
  }
}
