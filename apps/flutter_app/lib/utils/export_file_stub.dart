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
bool get supportsSystemFilePicker => false;

Future<void> downloadTextFile({
  required String filename,
  required String contents,
}) async {
  throw UnsupportedError('File download is not supported on this platform');
}

Future<SavedTextFile> saveTextFile({
  required String filename,
  required String contents,
  String? filePath,
}) async {
  throw UnsupportedError('Local file save is not supported on this platform');
}

Future<String?> pickSaveFilePath({
  required String suggestedName,
}) async {
  throw UnsupportedError(
      'System file picker is not supported on this platform');
}

Future<String> readTextFile({
  required String path,
}) async {
  throw UnsupportedError('Local file read is not supported on this platform');
}

Future<PickedTextFile?> pickTextFile() async {
  throw UnsupportedError(
      'System file picker is not supported on this platform');
}
