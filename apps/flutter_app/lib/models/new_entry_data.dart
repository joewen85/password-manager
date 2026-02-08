import 'package:password_manager_core/password_manager_core.dart';

class NewEntryData {
  const NewEntryData({required this.label, required this.payload});

  final String label;
  final CredentialPayload payload;
}
