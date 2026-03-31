import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class SavedTextFile {
  const SavedTextFile({
    required this.filename,
    required this.path,
  });

  final String filename;
  final String path;
}

class PickedTextFile {
  const PickedTextFile({
    required this.name,
    required this.path,
    required this.contents,
  });

  final String name;
  final String? path;
  final String contents;
}

bool get supportsLocalTextFileIO => true;
bool get supportsSystemFilePicker => true;

Future<void> downloadTextFile({
  required String filename,
  required String contents,
}) async {
  await saveTextFile(
    filename: filename,
    contents: contents,
  );
}

Future<SavedTextFile> saveTextFile({
  required String filename,
  required String contents,
  String? filePath,
}) async {
  final customPath = filePath?.trim() ?? '';
  if (customPath.isNotEmpty) {
    final resolvedPath = _resolveSavePath(
      filePath: customPath,
      fallbackFilename: filename,
    );
    final file = File(resolvedPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
    return SavedTextFile(
      filename: path.basename(file.path),
      path: file.path,
    );
  }
  try {
    final location = await getSaveLocation(
      suggestedName: filename,
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'JSON',
          extensions: <String>['json'],
        ),
      ],
    );
    if (location != null) {
      final file = File(location.path);
      await file.writeAsString(contents);
      return SavedTextFile(
        filename: path.basename(location.path),
        path: file.path,
      );
    }
  } on UnsupportedError {
  } catch (_) {}

  final directory = await getApplicationDocumentsDirectory();
  final exportDirectory = Directory(path.join(directory.path, 'exports'));
  if (!await exportDirectory.exists()) {
    await exportDirectory.create(recursive: true);
  }
  final file = File(path.join(exportDirectory.path, filename));
  await file.writeAsString(contents);
  return SavedTextFile(
    filename: filename,
    path: file.path,
  );
}

Future<String?> pickSaveFilePath({
  required String suggestedName,
}) async {
  try {
    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: const <XTypeGroup>[
        XTypeGroup(
          label: 'JSON',
          extensions: <String>['json'],
        ),
      ],
    );
    return location?.path;
  } on UnsupportedError {
    return null;
  } catch (_) {
    return null;
  }
}

Future<String> readTextFile({
  required String path,
}) async {
  final file = File(path);
  if (!await file.exists()) {
    throw FileSystemException('文件不存在', path);
  }
  return file.readAsString();
}

Future<PickedTextFile?> pickTextFile() async {
  const typeGroup = XTypeGroup(
    label: 'JSON',
    extensions: <String>['json'],
  );
  final file = await openFile(
    acceptedTypeGroups: const <XTypeGroup>[typeGroup],
  );
  if (file == null) {
    return null;
  }
  return PickedTextFile(
    name: file.name,
    path: file.path,
    contents: await file.readAsString(),
  );
}

String _resolveSavePath({
  required String filePath,
  required String fallbackFilename,
}) {
  final trimmed = filePath.trim();
  final expanded = trimmed.startsWith('~/')
      ? path.join(Platform.environment['HOME'] ?? '', trimmed.substring(2))
      : trimmed;
  if (expanded.endsWith('/') || expanded.endsWith('\\')) {
    return path.normalize(path.join(expanded, fallbackFilename));
  }
  final normalized = path.normalize(expanded);
  if (path.extension(normalized).isEmpty) {
    return '$normalized.json';
  }
  return normalized;
}
