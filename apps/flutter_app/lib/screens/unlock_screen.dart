import 'package:flutter/material.dart';

import '../state/vault_controller.dart';

class UnlockScreen extends StatefulWidget {
  const UnlockScreen({super.key, required this.controller});

  final VaultController controller;

  @override
  State<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends State<UnlockScreen> {
  final _passwordController = TextEditingController();
  final _totpController = TextEditingController();
  final _confirmController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _passwordController.dispose();
    _totpController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isInitialized = widget.controller.hasMasterKey;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF6F6F2), Color(0xFFE8F1F2)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isInitialized ? '解锁密码库' : '初始化密码库',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          isInitialized
                              ? '所有数据均使用 AES-256 加密。请输入主密码继续。'
                              : '首次使用，请设置主密码。',
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _passwordController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: '主密码',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) =>
                              (value == null || value.isEmpty)
                                  ? '必填'
                                  : null,
                        ),
                        if (!isInitialized) ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _confirmController,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: '确认主密码',
                              border: OutlineInputBorder(),
                            ),
                            validator: (value) {
                              if (value == null || value.isEmpty) {
                                return '必填';
                              }
                              if (value != _passwordController.text) {
                                return '两次输入不一致';
                              }
                              return null;
                            },
                          ),
                        ],
                        if (widget.controller.requireTotp && isInitialized) ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _totpController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: '2FA 验证码',
                              border: OutlineInputBorder(),
                            ),
                            validator: (value) =>
                                (value == null || value.isEmpty)
                                    ? '必填'
                                    : null,
                          ),
                        ],
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: () async {
                              if (!_formKey.currentState!.validate()) {
                                return;
                              }
                              final password = _passwordController.text.trim();
                              final success = isInitialized
                                  ? await widget.controller.unlock(
                                      password,
                                      totpCode: _totpController.text.trim(),
                                    )
                                  : await widget.controller.setupMasterPassword(
                                      password,
                                      _confirmController.text.trim(),
                                    );
                              if (!success && mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('操作失败'),
                                  ),
                                );
                              }
                            },
                            child: Text(isInitialized ? '解锁' : '初始化'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
