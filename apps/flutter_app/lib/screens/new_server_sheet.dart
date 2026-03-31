import 'package:flutter/material.dart';
import 'package:password_manager_core/password_manager_core.dart';

import '../widgets/category_picker_section.dart';

class NewServerSheetResult {
  const NewServerSheetResult({required this.label, required this.payload});

  final String label;
  final ServerAssetPayload payload;
}

class NewServerSheet extends StatefulWidget {
  const NewServerSheet({
    super.key,
    required this.availableAccounts,
    this.initialData,
    this.availableCategories = const <String>[],
    this.initialCategory = '',
    this.title = '新建服务器',
    this.submitLabel = '保存',
  });

  final List<VaultItem> availableAccounts;
  final NewServerSheetResult? initialData;
  final List<String> availableCategories;
  final String initialCategory;
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
  final _linkedAccountController = TextEditingController();
  String _selectedCategory = '';
  String _linkedAccountId = '';

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
      _linkedAccountId = data.payload.accountId ?? '';
      _selectedCategory = data.payload.category;
    } else {
      _selectedCategory = widget.initialCategory.trim();
    }
    _linkedAccountController.text = _linkedAccountLabel();
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
    _linkedAccountController.dispose();
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
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              _buildField(
                controller: _nameController,
                label: '服务器名称',
                requiredField: true,
              ),
              CategoryPickerSection(
                availableCategories: widget.availableCategories,
                selectedCategory: _selectedCategory,
                onChanged: (value) {
                  setState(() => _selectedCategory = value);
                },
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
              _buildLinkedAccountField(),
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
                label: '标签',
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
                          accountId: _linkedAccountId.isEmpty
                              ? null
                              : _linkedAccountId,
                          category: _selectedCategory,
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
        ),
        validator: requiredField
            ? (value) => (value == null || value.trim().isEmpty) ? '必填' : null
            : null,
      ),
    );
  }

  Widget _buildLinkedAccountField() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: _linkedAccountController,
        readOnly: true,
        onTap: _pickAccount,
        showCursor: false,
        enableInteractiveSelection: false,
        decoration: const InputDecoration(
          labelText: '关联账号（单选）',
          suffixIcon: Icon(Icons.search),
        ),
      ),
    );
  }

  String _linkedAccountLabel() {
    if (_linkedAccountId.trim().isEmpty) {
      return '不关联账号';
    }
    for (final item in widget.availableAccounts) {
      if (item.id == _linkedAccountId) {
        return item.label.isEmpty ? item.id : item.label;
      }
    }
    return '已删除账号';
  }

  Future<void> _pickAccount() async {
    if (!mounted) {
      return;
    }
    final searchController = TextEditingController();
    var query = '';
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('选择关联账号'),
          content: SizedBox(
            width: 360,
            height: 360,
            child: StatefulBuilder(
              builder: (context, setLocalState) {
                final trimmed = query.trim().toLowerCase();
                final filtered = trimmed.isEmpty
                    ? widget.availableAccounts
                    : widget.availableAccounts.where((item) {
                        final label = item.label.isEmpty ? item.id : item.label;
                        final lowerLabel = label.toLowerCase();
                        return lowerLabel.contains(trimmed) ||
                            item.id.toLowerCase().contains(trimmed);
                      }).toList();
                return Column(
                  children: [
                    TextField(
                      controller: searchController,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: '搜索账号',
                      ),
                      onChanged: (value) {
                        setLocalState(() => query = value);
                      },
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView(
                        children: [
                          ListTile(
                            title: const Text('不关联账号'),
                            onTap: () => Navigator.of(context).pop(''),
                          ),
                          if (filtered.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Center(child: Text('未找到匹配账号')),
                            )
                          else
                            for (final item in filtered)
                              ListTile(
                                title: Text(
                                  item.label.isEmpty ? item.id : item.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => Navigator.of(context).pop(item.id),
                              ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );
    searchController.dispose();
    if (!mounted) {
      return;
    }
    if (result != null) {
      setState(() {
        _linkedAccountId = result;
        _linkedAccountController.text = _linkedAccountLabel();
      });
    }
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
