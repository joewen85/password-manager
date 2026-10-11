import SwiftUI

struct SyncCenterView: View {
    @Bindable var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("Provider", value: store.syncSettings.providerType.title)
                    LabeledContent("Status", value: L10n.status(store.syncStatus))
                    LabeledContent("Revision", value: "\(store.syncSettings.lastSyncRevision)")
                    LabeledContent("Last Sync", value: lastSyncText)
                    if let message = store.syncSettings.lastSyncMessage,
                       !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        LabeledContent("Last Result") {
                            Text(L10n.status(message))
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                }

                Section("Recent Logs") {
                    if store.syncSettings.logs.isEmpty {
                        ContentUnavailableView(
                            "No Sync Logs",
                            systemImage: "list.bullet.rectangle"
                        )
                        .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        ForEach(Array(store.syncSettings.logs.prefix(8)), id: \.timestamp) { log in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(log.level.uppercased())
                                        .font(.caption.bold())
                                        .foregroundStyle(log.level == "error" ? Color.red : Color.accentColor)
                                    Spacer()
                                    Text(log.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(log.message.isEmpty ? "-" : L10n.status(log.message))
                                    .font(.callout)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if let statusMessage = store.statusMessage {
                    Section {
                        Text(L10n.status(statusMessage))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Sync")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarSpacer(.fixed)

                ToolbarItem {
                    Button {
                        openSettings()
                    } label: {
                        Label("Edit Sync Settings", systemImage: "gearshape")
                    }
                    .help("Edit Sync Settings")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        store.syncNow()
                    } label: {
                        Label {
                            Text("Run Sync Now")
                        } icon: {
                            if store.isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.syncSettings.providerType == .none || store.isSyncing)
                    .help("Run Sync Now")
                }
            }
        }
        .frame(minWidth: 520, minHeight: 460)
    }

    private var lastSyncText: String {
        store.syncSettings.lastSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? L10n.t("Never")
    }
}
