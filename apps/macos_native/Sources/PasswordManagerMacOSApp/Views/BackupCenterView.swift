import SwiftUI

struct BackupCenterView: View {
    @Bindable var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var backups: [BackupInfo] = []
    @State private var pendingRestore: BackupInfo?

    var body: some View {
        NavigationStack {
            Group {
                if backups.isEmpty {
                    ContentUnavailableView(
                        "No Backups",
                        systemImage: "externaldrive.badge.timemachine"
                    )
                } else {
                    List(backups) { backup in
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(backup.fileName)
                                    .lineLimit(1)
                                Text("\(Self.byteFormatter.string(fromByteCount: backup.sizeBytes)) - \(backup.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                pendingRestore = backup
                            } label: {
                                Label("Restore This Backup", systemImage: "clock.arrow.circlepath")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Backups")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarSpacer(.fixed)
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        store.runBackup()
                        refreshBackups()
                    } label: {
                        Label("Create Backup Now", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let statusMessage = store.statusMessage {
                    Text(L10n.status(statusMessage))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                        .background(.bar)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear(perform: refreshBackups)
        .alert("Restore Backup", isPresented: isShowingRestoreAlert) {
            Button("Restore", role: .destructive) {
                if let pendingRestore {
                    store.restoreBackup(fileName: pendingRestore.fileName)
                    refreshBackups()
                }
                pendingRestore = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRestore = nil
            }
        } message: {
            if let pendingRestore {
                Text(L10n.tf("Restore %@? Current vault data will be replaced.", pendingRestore.fileName))
            }
        }
    }

    private var isShowingRestoreAlert: Binding<Bool> {
        Binding(
            get: { pendingRestore != nil },
            set: { isShowing in
                if !isShowing {
                    pendingRestore = nil
                }
            }
        )
    }

    private func refreshBackups() {
        backups = store.listBackups()
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
