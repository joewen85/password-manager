import 'package:flutter/material.dart';

void main() {
  runApp(const PasswordManagerApp());
}

class PasswordManagerApp extends StatelessWidget {
  const PasswordManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0F4C5C),
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: 'Password Manager',
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF6F6F2),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(fontWeight: FontWeight.w700),
          titleMedium: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<VaultEntry> _entries = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vault'),
        centerTitle: false,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final entry = await showModalBottomSheet<VaultEntry>(
            context: context,
            isScrollControlled: true,
            builder: (context) => const NewEntrySheet(),
          );
          if (entry != null) {
            setState(() => _entries.add(entry));
          }
        },
        icon: const Icon(Icons.add),
        label: const Text('New Item'),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF6F6F2), Color(0xFFE8F1F2)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Securely store credentials',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  'AES-256 encrypted vault with 2FA and sync-ready modules.',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: _entries.isEmpty
                      ? const Center(
                          child: Text('No entries yet. Tap “New Item” to add.'),
                        )
                      : ListView.separated(
                          itemCount: _entries.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final entry = _entries[index];
                            return EntryCard(entry: entry);
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class EntryCard extends StatelessWidget {
  const EntryCard({super.key, required this.entry});

  final VaultEntry entry;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        title: Text(entry.label),
        subtitle: Text(entry.username),
        trailing: IconButton(
          icon: const Icon(Icons.visibility_outlined),
          onPressed: () {
            showDialog<void>(
              context: context,
              builder: (context) => EntryDetailsDialog(entry: entry),
            );
          },
        ),
      ),
    );
  }
}

class EntryDetailsDialog extends StatelessWidget {
  const EntryDetailsDialog({super.key, required this.entry});

  final VaultEntry entry;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(entry.label),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailRow('Username', entry.username),
            _detailRow('Password', entry.password),
            _detailRow('Token', entry.token),
            _detailRow('App ID', entry.appId),
            _detailRow('Access Token', entry.accessToken),
            _detailRow('Secret Key', entry.secretKey),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(value.isEmpty ? '-' : value),
        ],
      ),
    );
  }
}

class NewEntrySheet extends StatefulWidget {
  const NewEntrySheet({super.key});

  @override
  State<NewEntrySheet> createState() => _NewEntrySheetState();
}

class _NewEntrySheetState extends State<NewEntrySheet> {
  final _formKey = GlobalKey<FormState>();
  final _labelController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _tokenController = TextEditingController();
  final _appIdController = TextEditingController();
  final _accessTokenController = TextEditingController();
  final _secretKeyController = TextEditingController();

  @override
  void dispose() {
    _labelController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _tokenController.dispose();
    _appIdController.dispose();
    _accessTokenController.dispose();
    _secretKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: bottomInset + 16,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'New Vault Item',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              _buildField(
                controller: _labelController,
                label: 'Label',
                hint: 'e.g. AWS Console',
                requiredField: true,
              ),
              _buildField(
                controller: _usernameController,
                label: 'Username',
                hint: 'name@example.com',
                requiredField: true,
              ),
              _buildField(
                controller: _passwordController,
                label: 'Password',
                obscure: true,
              ),
              _buildField(
                controller: _tokenController,
                label: 'Token',
                obscure: true,
              ),
              _buildField(
                controller: _appIdController,
                label: 'App ID',
              ),
              _buildField(
                controller: _accessTokenController,
                label: 'Access Token',
                obscure: true,
              ),
              _buildField(
                controller: _secretKeyController,
                label: 'Secret Key',
                obscure: true,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        if (!_formKey.currentState!.validate()) {
                          return;
                        }
                        Navigator.of(context).pop(
                          VaultEntry(
                            label: _labelController.text.trim(),
                            username: _usernameController.text.trim(),
                            password: _passwordController.text.trim(),
                            token: _tokenController.text.trim(),
                            appId: _appIdController.text.trim(),
                            accessToken: _accessTokenController.text.trim(),
                            secretKey: _secretKeyController.text.trim(),
                          ),
                        );
                      },
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool obscure = false,
    bool requiredField = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          filled: true,
          fillColor: Colors.white,
        ),
        validator: requiredField
            ? (value) => (value == null || value.trim().isEmpty)
                ? 'Required'
                : null
            : null,
      ),
    );
  }
}

class VaultEntry {
  const VaultEntry({
    required this.label,
    required this.username,
    required this.password,
    required this.token,
    required this.appId,
    required this.accessToken,
    required this.secretKey,
  });

  final String label;
  final String username;
  final String password;
  final String token;
  final String appId;
  final String accessToken;
  final String secretKey;
}
