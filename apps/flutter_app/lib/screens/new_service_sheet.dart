import 'package:flutter/material.dart';
import 'package:password_manager_core/password_manager_core.dart';

class NewServiceSheetResult {
  const NewServiceSheetResult({required this.label, required this.payload});

  final String label;
  final ServicePayload payload;
}

class NewServiceSheet extends StatefulWidget {
  const NewServiceSheet({
    super.key,
    required this.availableAccounts,
    required this.availableServers,
    this.initialData,
    this.title = '新建服务',
    this.submitLabel = '保存',
  });

  final List<VaultItem> availableAccounts;
  final List<VaultItem> availableServers;
  final NewServiceSheetResult? initialData;
  final String title;
  final String submitLabel;

  @override
  State<NewServiceSheet> createState() => _NewServiceSheetState();
}

class _NewServiceSheetState extends State<NewServiceSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _connectionAddressController = TextEditingController();
  final _connectionPortController = TextEditingController();
  final _linkedAccountController = TextEditingController();
  final _notesController = TextEditingController();
  final _tagsController = TextEditingController();
  final List<_AccountForm> _accounts = [];
  final Set<String> _selectedServerIds = {};
  String _linkedAccountId = '';

  @override
  void initState() {
    super.initState();
    final data = widget.initialData;
    if (data != null) {
      _nameController.text = data.payload.name;
      _connectionAddressController.text = data.payload.connectionAddress;
      _connectionPortController.text = data.payload.connectionPort;
      _linkedAccountId = data.payload.accountId ?? '';
      _selectedServerIds.addAll(data.payload.serverIds);
      _notesController.text = data.payload.notes;
      _tagsController.text = data.payload.tags.join(', ');
      for (final account in data.payload.accounts) {
        _accounts.add(_AccountForm.fromPayload(account));
      }
    }
    if (_accounts.isEmpty) {
      _accounts.add(_AccountForm());
    }
    _linkedAccountController.text = _linkedAccountLabel();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _connectionAddressController.dispose();
    _connectionPortController.dispose();
    _linkedAccountController.dispose();
    _notesController.dispose();
    _tagsController.dispose();
    for (final account in _accounts) {
      account.dispose();
    }
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
                label: '服务名称',
                requiredField: true,
              ),
              _buildField(
                controller: _connectionAddressController,
                label: '连接地址',
                hint: '例如 service.example.com',
              ),
              _buildField(
                controller: _connectionPortController,
                label: '端口',
                hint: '443',
              ),
              const SizedBox(height: 4),
              _buildLinkedAccountField(),
              const SizedBox(height: 4),
              _buildServerSelector(),
              const SizedBox(height: 12),
              Text(
                '服务账号',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              ..._buildAccountCards(),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _addAccount,
                  icon: const Icon(Icons.add),
                  label: const Text('新增账号'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: _buildField(
                  controller: _notesController,
                  label: '备注',
                  maxLines: 3,
                ),
              ),
              _buildField(
                controller: _tagsController,
                label: '分类标签',
                hint: '多个标签用逗号分隔',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _handleSubmit,
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

  Widget _buildLinkedAccountField() {
    return TextFormField(
      controller: _linkedAccountController,
      readOnly: true,
      onTap: _pickAccount,
      showCursor: false,
      enableInteractiveSelection: false,
      decoration: const InputDecoration(
        labelText: '关联账号（单选）',
        suffixIcon: Icon(Icons.search),
      ),
    );
  }

  Widget _buildServerSelector() {
    final labelMap = <String, String>{
      for (final item in widget.availableServers)
        item.id: item.label.isEmpty ? item.id : item.label,
    };
    final selected = _selectedServerIds.toList();
    selected.sort((a, b) => (labelMap[a] ?? a).compareTo(labelMap[b] ?? b));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '关联服务器（可多选）',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        if (selected.isEmpty)
          Text(
            widget.availableServers.isEmpty ? '暂无服务器' : '未选择服务器',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (selected.isNotEmpty)
          LayoutBuilder(
            builder: (context, constraints) {
              final maxWidth = constraints.maxWidth;
              return Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final id in selected)
                    Chip(
                      label: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: maxWidth),
                        child: Text(
                          labelMap[id] ?? '已删除服务器',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      onDeleted: () => _removeServer(id),
                    ),
                ],
              );
            },
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: widget.availableServers.isEmpty ? null : _pickServers,
          icon: const Icon(Icons.dns_rounded),
          label: const Text('选择服务器'),
        ),
      ],
    );
  }

  List<Widget> _buildAccountCards() {
    return [
      for (var i = 0; i < _accounts.length; i++)
        Card(
          key: ValueKey(_accounts[i].id),
          margin: EdgeInsets.only(
            bottom: i == _accounts.length - 1 ? 0 : 12,
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '账号 ${i + 1}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: _accounts.length <= 1
                          ? null
                          : () => _removeAccount(i),
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '删除账号',
                    ),
                  ],
                ),
                _buildField(
                  controller: _accounts[i].usernameController,
                  label: '账号',
                  hint: '例如 admin@example.com',
                ),
                _buildField(
                  controller: _accounts[i].passwordController,
                  label: '密码',
                  obscure: true,
                ),
                _buildField(
                  controller: _accounts[i].noteController,
                  label: '账号备注',
                  maxLines: 2,
                  bottomSpacing: 0,
                ),
              ],
            ),
          ),
        ),
    ];
  }

  void _addAccount() {
    setState(() => _accounts.add(_AccountForm()));
  }

  void _removeAccount(int index) {
    final removed = _accounts.removeAt(index);
    removed.dispose();
    setState(() {});
  }

  void _removeServer(String id) {
    setState(() => _selectedServerIds.remove(id));
  }

  Future<void> _pickServers() async {
    if (!mounted) {
      return;
    }
    final selected = Set<String>.from(_selectedServerIds);
    final searchController = TextEditingController();
    var query = '';
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('选择服务器'),
          content: SizedBox(
            width: 360,
            height: 360,
            child: StatefulBuilder(
              builder: (context, setLocalState) {
                final trimmed = query.trim().toLowerCase();
                final filtered = trimmed.isEmpty
                    ? widget.availableServers
                    : widget.availableServers.where((item) {
                        final label =
                            item.label.isEmpty ? item.id : item.label;
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
                        hintText: '搜索服务器',
                      ),
                      onChanged: (value) {
                        setLocalState(() => query = value);
                      },
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(child: Text('未找到匹配服务器'))
                          : ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final item = filtered[index];
                                final isSelected = selected.contains(item.id);
                                return CheckboxListTile(
                                  value: isSelected,
                                  title: Text(
                                    item.label.isEmpty ? item.id : item.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onChanged: (value) {
                                    setLocalState(() {
                                      if (value == true) {
                                        selected.add(item.id);
                                      } else {
                                        selected.remove(item.id);
                                      }
                                    });
                                  },
                                );
                              },
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
            FilledButton(
              onPressed: () => Navigator.of(context).pop(selected),
              child: const Text('确定'),
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
        _selectedServerIds
          ..clear()
          ..addAll(result);
      });
    }
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
                        final label =
                            item.label.isEmpty ? item.id : item.label;
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
                                onTap: () =>
                                    Navigator.of(context).pop(item.id),
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

  void _handleSubmit() {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final name = _nameController.text.trim();
    final accounts = _accounts
        .map((entry) => entry.toPayload())
        .where((entry) =>
            entry.username.isNotEmpty ||
            entry.password.isNotEmpty ||
            entry.note.isNotEmpty)
        .toList();
    if (accounts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少添加一个账号')),
      );
      return;
    }
    final payload = ServicePayload(
      name: name,
      connectionAddress: _connectionAddressController.text.trim(),
      connectionPort: _connectionPortController.text.trim(),
      accountId: _linkedAccountId.isEmpty ? null : _linkedAccountId,
      serverIds: _selectedServerIds.toList(),
      accounts: accounts,
      notes: _notesController.text.trim(),
      tags: _parseTags(_tagsController.text),
    );
    Navigator.of(context).pop(
      NewServiceSheetResult(
        label: name,
        payload: payload,
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
    double bottomSpacing = 12,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSpacing),
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
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

class _AccountForm {
  _AccountForm({String? username, String? password, String? note})
      : id = _nextId++,
        usernameController = TextEditingController(text: username ?? ''),
        passwordController = TextEditingController(text: password ?? ''),
        noteController = TextEditingController(text: note ?? '');

  static int _nextId = 0;

  final int id;

  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final TextEditingController noteController;

  factory _AccountForm.fromPayload(ServiceAccount payload) {
    return _AccountForm(
      username: payload.username,
      password: payload.password,
      note: payload.note,
    );
  }

  ServiceAccount toPayload() {
    return ServiceAccount(
      username: usernameController.text.trim(),
      password: passwordController.text.trim(),
      note: noteController.text.trim(),
    );
  }

  void dispose() {
    usernameController.dispose();
    passwordController.dispose();
    noteController.dispose();
  }
}
