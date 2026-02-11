import 'package:flutter/material.dart';
import 'package:password_manager_core/password_manager_core.dart';

import '../models/new_entry_data.dart';

class NewEntrySheet extends StatefulWidget {
  const NewEntrySheet({
    super.key,
    this.initialData,
    this.title = '新建条目',
    this.submitLabel = '保存',
  });

  final NewEntryData? initialData;
  final String title;
  final String submitLabel;

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
  void initState() {
    super.initState();
    final data = widget.initialData;
    if (data != null) {
      _labelController.text = data.label;
      _usernameController.text = data.payload.username;
      _passwordController.text = data.payload.password;
      _tokenController.text = data.payload.token;
      _appIdController.text = data.payload.appId;
      _accessTokenController.text = data.payload.accessToken;
      _secretKeyController.text = data.payload.secretKey;
    }
  }

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
              Text(
                widget.title,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              _buildField(
                controller: _labelController,
                label: '标题',
                hint: '例如 AWS 控制台',
                requiredField: true,
              ),
              _buildField(
                controller: _usernameController,
                label: '用户名',
                hint: 'name@example.com',
                requiredField: true,
              ),
              _buildField(
                controller: _passwordController,
                label: '密码',
                obscure: true,
              ),
              _buildField(
                controller: _tokenController,
                label: '令牌',
                obscure: true,
              ),
              _buildField(
                controller: _appIdController,
                label: '应用ID',
              ),
              _buildField(
                controller: _accessTokenController,
                label: '访问令牌',
                obscure: true,
              ),
              _buildField(
                controller: _secretKeyController,
                label: '密钥',
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
                        final payload = CredentialPayload(
                          username: _usernameController.text.trim(),
                          password: _passwordController.text.trim(),
                          token: _tokenController.text.trim(),
                          appId: _appIdController.text.trim(),
                          accessToken: _accessTokenController.text.trim(),
                          secretKey: _secretKeyController.text.trim(),
                        );
                        Navigator.of(context).pop(
                          NewEntryData(
                            label: _labelController.text.trim(),
                            payload: payload,
                          ),
                        );
                      },
                      child: Text(widget.submitLabel),
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
                ? '必填'
                : null
            : null,
      ),
    );
  }
}
