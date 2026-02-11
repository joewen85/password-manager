import 'dart:convert';
import 'dart:html' as html;

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
