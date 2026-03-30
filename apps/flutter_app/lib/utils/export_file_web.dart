import 'dart:convert';
import 'dart:html' as html;

import 'package:file_selector/file_selector.dart';

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

bool get supportsLocalTextFileIO => false;
bool get supportsSystemFilePicker => true;

Future<void> downloadTextFile({
  required String filename,
  required String contents,
}) async {
  final uri = Uri.dataFromString(
    contents,
    mimeType: 'application/json',
    encoding: utf8,
  );
  final anchor = html.AnchorElement(href: uri.toString())
    ..setAttribute('download', filename)
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
}

Future<SavedTextFile> saveTextFile({
  required String filename,
  required String contents,
}) async {
  await downloadTextFile(
    filename: filename,
    contents: contents,
  );
  return SavedTextFile(
    filename: filename,
    path: filename,
  );
}

Future<String> readTextFile({
  required String path,
}) async {
  throw UnsupportedError('Local file read is not supported on web');
}

Future<PickedTextFile?> pickTextFile() async {
  const typeGroup = XTypeGroup(
    label: 'JSON',
    extensions: <String>['json'],
    webWildCards: <String>['application/json'],
  );
  final file = await openFile(
    acceptedTypeGroups: const <XTypeGroup>[typeGroup],
  );
  if (file == null) {
    return null;
  }
  return PickedTextFile(
    name: file.name,
    path: null,
    contents: await file.readAsString(),
  );
}
