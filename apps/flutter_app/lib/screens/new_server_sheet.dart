import 'package:flutter/material.dart';
import 'package:password_manager_core/password_manager_core.dart';

class NewServerSheetResult {
  const NewServerSheetResult({required this.label, required this.payload});

  final String label;
  final ServerAssetPayload payload;
}

class NewServerSheet extends StatefulWidget {
  const NewServerSheet({
    super.key,
    this.initialData,
    this.title = '新建服务器',
    this.submitLabel = '保存',
  });

  final NewServerSheetResult? initialData;
  final String title;
  final String submitLabel;

  @override
  State<NewServerSheet> createState() => _NewServerSheetState();
}

class _NewServerSheetState extends State<NewServerSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _ipController = TextEditingController();
  final _portController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _configController = TextEditingController();
  final _osController = TextEditingController();
  final _locationController = TextEditingController();
  final _notesController = TextEditingController();
  final _tagsController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final data = widget.initialData;
    if (data != null) {
      _nameController.text = data.payload.name;
      _ipController.text = data.payload.ipAddress;
      _portController.text = data.payload.port;
      _usernameController.text = data.payload.username;
      _passwordController.text = data.payload.password;
      _configController.text = data.payload.basicConfig;
      _osController.text = data.payload.operatingSystem;
      _locationController.text = data.payload.location;
      _notesController.text = data.payload.notes;
      _tagsController.text = data.payload.tags.join(', ');
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _ipController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _configController.dispose();
    _osController.dispose();
    _locationController.dispose();
    _notesController.dispose();
    _tagsController.dispose();
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
                controller: _nameController,
                label: '服务器名称',
                requiredField: true,
              ),
              _buildField(
                controller: _ipController,
                label: 'IP地址',
                requiredField: true,
              ),
              _buildField(
                controller: _portController,
                label: '端口',
                hint: '22',
              ),
              _buildField(
                controller: _usernameController,
                label: '登录用户名',
              ),
              _buildField(
                controller: _passwordController,
                label: '登录密码',
                obscure: true,
              ),
              _buildField(
                controller: _configController,
                label: '基础配置',
              ),
              _buildField(
                controller: _osController,
                label: '操作系统',
              ),
              _buildField(
                controller: _locationController,
                label: '位置',
              ),
              _buildField(
                controller: _tagsController,
                label: '分类标签',
                hint: '多个标签用逗号分隔',
              ),
              _buildField(
                controller: _notesController,
                label: '备注项',
                maxLines: 4,
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
                        final payload = ServerAssetPayload(
                          name: _nameController.text.trim(),
                          ipAddress: _ipController.text.trim(),
                          port: _portController.text.trim(),
                          username: _usernameController.text.trim(),
                          password: _passwordController.text.trim(),
                          basicConfig: _configController.text.trim(),
                          operatingSystem: _osController.text.trim(),
                          location: _locationController.text.trim(),
                          notes: _notesController.text.trim(),
                          tags: _parseTags(_tagsController.text),
                        );
                        Navigator.of(context).pop(
                          NewServerSheetResult(
                            label: _nameController.text.trim(),
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
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        maxLines: maxLines,
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

  List<String> _parseTags(String raw) {
    return raw
        .split(',')
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toSet()
        .toList();
  }
}
