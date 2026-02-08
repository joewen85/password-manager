import 'package:flutter/material.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = await PasswordManagerApp.bootstrap();
  runApp(app);
}
