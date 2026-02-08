import 'package:flutter/material.dart';
import 'package:password_manager_core/password_manager_core.dart';

import '../models/new_entry_data.dart';
import '../state/vault_controller.dart';
import '../widgets/entry_details_dialog.dart';
import 'new_entry_sheet.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});

  final VaultController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vault'),
        actions: [
          IconButton(
            onPressed: controller.syncNow,
            icon: const Icon(Icons.sync),
            tooltip: 'Sync',
          ),
          IconButton(
            onPressed: controller.runBackup,
            icon: const Icon(Icons.backup_outlined),
            tooltip: 'Backup',
          ),
          IconButton(
            onPressed: controller.lock,
            icon: const Icon(Icons.lock_outline),
            tooltip: 'Lock',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final data = await showModalBottomSheet<NewEntryData>(
            context: context,
            isScrollControlled: true,
            builder: (context) => const NewEntrySheet(),
          );
          if (data != null) {
            await controller.addEntry(
              label: data.label,
              payload: data.payload,
            );
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
                const Text(
                  'Securely store credentials',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  'AES-256 encrypted vault with 2FA and sync-ready modules.',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: AnimatedBuilder(
                    animation: controller,
                    builder: (context, _) {
                      final items = controller.items;
                      if (items.isEmpty) {
                        return const Center(
                          child: Text('No entries yet. Tap “New Item” to add.'),
                        );
                      }
                      return ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final item = items[index];
                          return EntryCard(
                            item: item,
                            onOpen: () {
                              showDialog<void>(
                                context: context,
                                builder: (context) => EntryDetailsDialog(
                                  controller: controller,
                                  item: item,
                                ),
                              );
                            },
                          );
                        },
                      );
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
  const EntryCard({super.key, required this.item, required this.onOpen});

  final VaultItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        title: Text(item.label),
        subtitle: Text('Updated ${item.updatedAt.toLocal()}'),
        trailing: IconButton(
          icon: const Icon(Icons.visibility_outlined),
          onPressed: onOpen,
        ),
      ),
    );
  }
}
