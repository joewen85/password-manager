import 'package:flutter/material.dart';

import '../state/vault_controller.dart';
import '../widgets/app_background.dart';
import '../widgets/fade_slide.dart';

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
  final _passwordFocusNode = FocusNode();
  final _totpFocusNode = FocusNode();
  final _confirmFocusNode = FocusNode();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _passwordController.dispose();
    _totpController.dispose();
    _confirmController.dispose();
    _passwordFocusNode.dispose();
    _totpFocusNode.dispose();
    _confirmFocusNode.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit({required bool isInitialized}) async {
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
  }

  @override
  Widget build(BuildContext context) {
    final isInitialized = widget.controller.hasMasterKey;
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: FadeSlide(
                delay: const Duration(milliseconds: 80),
                offset: const Offset(0, 24),
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surface
                        .withOpacity(0.96),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .outlineVariant
                          .withOpacity(0.7),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(
                          Theme.of(context).brightness == Brightness.dark
                              ? 0.35
                              : 0.08,
                        ),
                        blurRadius: 24,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primaryContainer,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Icon(
                                Icons.lock_outline,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                isInitialized ? '解锁密码库' : '初始化密码库',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          isInitialized
                              ? '所有数据均使用 AES-256 加密。请输入主密码继续。'
                              : '首次使用，请设置主密码。',
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 20),
                        TextFormField(
                          controller: _passwordController,
                          focusNode: _passwordFocusNode,
                          obscureText: true,
                          textInputAction: !isInitialized
                              ? TextInputAction.next
                              : widget.controller.requireTotp
                                  ? TextInputAction.next
                                  : TextInputAction.done,
                          decoration: const InputDecoration(
                            labelText: '主密码',
                          ),
                          onFieldSubmitted: (_) {
                            if (!isInitialized) {
                              FocusScope.of(context)
                                  .requestFocus(_confirmFocusNode);
                              return;
                            }
                            if (widget.controller.requireTotp) {
                              FocusScope.of(context)
                                  .requestFocus(_totpFocusNode);
                              return;
                            }
                            _handleSubmit(isInitialized: true);
                          },
                          validator: (value) =>
                              (value == null || value.isEmpty)
                                  ? '必填'
                                  : null,
                        ),
                        if (!isInitialized) ...[
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _confirmController,
                            focusNode: _confirmFocusNode,
                            obscureText: true,
                            textInputAction: TextInputAction.done,
                            decoration: const InputDecoration(
                              labelText: '确认主密码',
                            ),
                            onFieldSubmitted: (_) =>
                                _handleSubmit(isInitialized: false),
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
                            focusNode: _totpFocusNode,
                            keyboardType: TextInputType.number,
                            textInputAction: TextInputAction.done,
                            decoration: const InputDecoration(
                              labelText: '2FA 验证码',
                            ),
                            onFieldSubmitted: (_) =>
                                _handleSubmit(isInitialized: true),
                            validator: (value) =>
                                (value == null || value.isEmpty)
                                    ? '必填'
                                    : null,
                          ),
                        ],
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: () =>
                                _handleSubmit(isInitialized: isInitialized),
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
