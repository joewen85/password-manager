import 'dart:convert';

import 'package:http/http.dart' as http;

class RemoteSyncResult {
  const RemoteSyncResult({
    required this.payload,
    required this.statusCode,
  });

  final String? payload;
  final int statusCode;
}

abstract class RemoteSyncClient {
  Future<RemoteSyncResult> download();
  Future<RemoteSyncResult> upload(String payload);
}

class WebDavSyncClient implements RemoteSyncClient {
  WebDavSyncClient({
    required this.baseUrl,
    required this.remotePath,
    this.username,
    this.password,
  });

  final String baseUrl;
  final String remotePath;
  final String? username;
  final String? password;

  Uri _buildUri() {
    final base = Uri.parse(baseUrl);
    final path = _normalizedPath();
    final mergedPath = base.path.endsWith('/')
        ? '${base.path.substring(0, base.path.length - 1)}$path'
        : '${base.path}$path';
    return base.replace(path: mergedPath);
  }

  String _normalizedPath() {
    var path = remotePath.trim();
    if (path.isEmpty) {
      path = '/vault.json';
    }
    if (!path.startsWith('/')) {
      path = '/$path';
    }
    if (path.endsWith('/')) {
      path = '${path}vault.json';
    }
    return path;
  }

  Map<String, String> _headers() {
    if ((username ?? '').isEmpty && (password ?? '').isEmpty) {
      return {};
    }
    final token =
        base64Encode(utf8.encode('${username ?? ''}:${password ?? ''}'));
    return {'Authorization': 'Basic $token'};
  }

  @override
  Future<RemoteSyncResult> download() async {
    final response = await http.get(_buildUri(), headers: _headers());
    if (response.statusCode == 404 || response.statusCode == 204) {
      return const RemoteSyncResult(payload: null, statusCode: 404);
    }
    return RemoteSyncResult(
      payload: response.body.isEmpty ? null : response.body,
      statusCode: response.statusCode,
    );
  }

  @override
  Future<RemoteSyncResult> upload(String payload) async {
    final response = await http.put(
      _buildUri(),
      headers: {
        'Content-Type': 'application/json',
        ..._headers(),
      },
      body: payload,
    );
    return RemoteSyncResult(payload: null, statusCode: response.statusCode);
  }
}

class PresignedUrlSyncClient implements RemoteSyncClient {
  PresignedUrlSyncClient({
    required this.downloadUrl,
    required this.uploadUrl,
  });

  final String downloadUrl;
  final String uploadUrl;

  @override
  Future<RemoteSyncResult> download() async {
    if (downloadUrl.trim().isEmpty) {
      return const RemoteSyncResult(payload: null, statusCode: 400);
    }
    final response = await http.get(Uri.parse(downloadUrl));
    if (response.statusCode == 404 || response.statusCode == 204) {
      return const RemoteSyncResult(payload: null, statusCode: 404);
    }
    return RemoteSyncResult(
      payload: response.body.isEmpty ? null : response.body,
      statusCode: response.statusCode,
    );
  }

  @override
  Future<RemoteSyncResult> upload(String payload) async {
    if (uploadUrl.trim().isEmpty) {
      return const RemoteSyncResult(payload: null, statusCode: 400);
    }
    final response = await http.put(
      Uri.parse(uploadUrl),
      headers: {'Content-Type': 'application/json'},
      body: payload,
    );
    return RemoteSyncResult(payload: null, statusCode: response.statusCode);
  }
}
