import SwiftUI

struct SettingsView: View {
    @Bindable var store: VaultStore
    @State private var totpSecret = ""
    @State private var syncDraft = SyncSettings.defaults()

    var body: some View {
        Form {
            Section("Security") {
                Toggle(
                    "Require 2FA code on unlock",
                    isOn: Binding(
                        get: { store.requireTotp },
                        set: { store.setRequireTotp($0) }
                    )
                )
                SecureField("TOTP shared secret", text: $totpSecret)
                    .onSubmit {
                        store.setTotpSecret(totpSecret)
                    }
                Button("Save 2FA Secret") {
                    store.setTotpSecret(totpSecret)
                }
                .disabled(totpSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Sync") {
                Picker("Provider", selection: $syncDraft.providerType) {
                    ForEach(SyncProviderType.allCases, id: \.self) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                TextField("WebDAV URL", text: $syncDraft.webdavUrl)
                TextField("WebDAV path", text: $syncDraft.webdavPath)
                TextField("WebDAV username", text: $syncDraft.webdavUsername)
                SecureField("WebDAV password", text: $syncDraft.webdavPassword)
                TextField("Presigned download URL", text: $syncDraft.presignedDownloadUrl)
                SecureField("Presigned upload URL", text: $syncDraft.presignedUploadUrl)
                Toggle("Auto sync", isOn: $syncDraft.autoSyncEnabled)
                LabeledContent("Auto sync interval") {
                    HStack {
                        Stepper(
                            "\(syncDraft.autoSyncIntervalValue)",
                            value: $syncDraft.autoSyncIntervalValue,
                            in: 1...1440,
                            step: syncDraft.autoSyncIntervalUnit == .minutes ? 5 : 1
                        )
                        Picker("Unit", selection: $syncDraft.autoSyncIntervalUnit) {
                            ForEach(SyncIntervalUnit.allCases, id: \.self) { unit in
                                Text(unit.title).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }
                Toggle("Sync on unlock", isOn: $syncDraft.autoSyncOnUnlock)
                Picker("Conflict strategy", selection: $syncDraft.conflictStrategy) {
                    ForEach(SyncSettingsConflictStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                Toggle("Sync master key metadata", isOn: $syncDraft.syncMasterKey)
                LabeledContent("Device", value: syncDraft.deviceId)
                LabeledContent("Revision", value: "\(syncDraft.lastSyncRevision)")
                Button("Save Sync Settings") {
                    syncDraft.autoSyncIntervalMinutes = syncDraft.autoSyncIntervalValue.toIntervalMinutes(
                        unit: syncDraft.autoSyncIntervalUnit
                    )
                    store.updateSyncSettings(syncDraft)
                }
            }

            LabeledContent("Sync", value: store.syncStatus)
            LabeledContent("Backup", value: store.lastBackupStatus)
            if let statusMessage = store.statusMessage {
                LabeledContent("Vault", value: statusMessage)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
        .onAppear {
            totpSecret = store.totpSecret
            syncDraft = store.syncSettings
        }
    }
}
