import 'package:password_manager_core/password_manager_core.dart';
import 'package:test/test.dart';

void main() {
  test('uses accessKey and keeps backward compatibility for accessToken', () {
    final legacy = CredentialPayload.fromJson(const {
      'username': 'u',
      'password': 'p',
      'token': '',
      'appId': '',
      'accessToken': 'legacy-token',
      'secretKey': '',
      'notes': '',
      'tags': <String>[],
      'category': '',
    });
    expect(legacy.accessKey, 'legacy-token');

    final current = CredentialPayload(
      username: 'u',
      password: 'p',
      token: '',
      appId: '',
      accessKey: 'new-key',
      secretKey: '',
      notes: '',
      tags: const <String>[],
    );
    final json = current.toJson();
    expect(json['accessKey'], 'new-key');
    expect(json.containsKey('accessToken'), isFalse);
  });
}
