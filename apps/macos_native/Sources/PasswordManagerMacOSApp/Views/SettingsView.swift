import SwiftUI

struct SettingsView: View {
    @Bindable var store: VaultStore
    @Bindable var preferences: AppPreferences
    @State private var totpSecret = ""
    @State private var syncDraft = SyncSettings.defaults()
    @State private var isPresentingClearData = false
    @State private var clearDataPassword = ""
    @State private var clearDataError: String?
    @State private var isBiometricUnlockEnabled = false
    @State private var isPresentingBiometricSetup = false
    @State private var biometricPassword = ""
    @State private var biometricMessage: String?
    @State private var biometricError: String?
    @State private var isSavingBiometricCredential = false

    private let biometricCredentialStore = MacBiometricCredentialStore()

    var body: some View {
        Form {
            Section(L10n.t("App")) {
                Picker(L10n.t("Language"), selection: $preferences.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }

                Picker(L10n.t("Appearance"), selection: $preferences.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
            }

            Section(L10n.t("Security")) {
                Toggle(
                    L10n.t("Require 2FA code on unlock"),
                    isOn: Binding(
                        get: { store.requireTotp },
                        set: { store.setRequireTotp($0) }
                    )
                )
                SecureField(L10n.t("TOTP shared secret"), text: $totpSecret)
                    .onSubmit {
                        store.setTotpSecret(totpSecret)
                    }
                Button(L10n.t("Save 2FA Secret")) {
                    store.setTotpSecret(totpSecret)
                }
                .disabled(totpSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Toggle(
                    L10n.t("Touch ID Unlock"),
                    isOn: Binding(
                        get: { isBiometricUnlockEnabled },
                        set: { setBiometricUnlockEnabled($0) }
                    )
                )
                .disabled(!biometricCredentialStore.canAuthenticate())

                Text(L10n.t("Use Touch ID instead of entering the master password on this Mac."))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if !biometricCredentialStore.canAuthenticate() {
                    Text(L10n.t("Touch ID unlock is not available on this Mac."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let biometricMessage {
                    Text(L10n.t(biometricMessage))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let biometricError {
                    Text(L10n.status(biometricError))
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                LabeledContent(L10n.t("Idle auto-lock")) {
                    HStack(spacing: 8) {
                        TextField(
                            "",
                            value: idleAutoLockMinutesBinding,
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 96)

                        Text(L10n.t("Minutes"))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 56, alignment: .leading)

                        if preferences.idleAutoLockMinutes == 0 {
                            Text(L10n.t("Off"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 40, alignment: .leading)
                        }
                    }
                }

                Text(L10n.t("Lock the vault after the app is idle for the selected number of minutes. Enter 0 to disable."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("Sync")) {
                Picker(L10n.t("Provider"), selection: $syncDraft.providerType) {
                    ForEach(SyncProviderType.allCases, id: \.self) { provider in
                        Text(provider.title).tag(provider)
                    }
                }

                switch syncDraft.providerType {
                case .none:
                    Text(L10n.t("No sync provider selected."))
                        .foregroundStyle(.secondary)
                case .webdav, .nasWebdav:
                    TextField(L10n.t("WebDAV URL"), text: $syncDraft.webdavUrl)
                    TextField(L10n.t("WebDAV path"), text: $syncDraft.webdavPath)
                    TextField(L10n.t("WebDAV username"), text: $syncDraft.webdavUsername)
                    SecureField(L10n.t("WebDAV password"), text: $syncDraft.webdavPassword)
                case .s3Presigned:
                    TextField(L10n.t("Presigned download URL"), text: $syncDraft.presignedDownloadUrl)
                    SecureField(L10n.t("Presigned upload URL"), text: $syncDraft.presignedUploadUrl)
                }

                Toggle(L10n.t("Auto sync"), isOn: $syncDraft.autoSyncEnabled)
                LabeledContent(L10n.t("Auto sync interval")) {
                    HStack {
                        Stepper(
                            "\(syncDraft.autoSyncIntervalValue)",
                            value: $syncDraft.autoSyncIntervalValue,
                            in: 1...1440,
                            step: syncDraft.autoSyncIntervalUnit == .minutes ? 5 : 1
                        )
                        Picker(L10n.t("Unit"), selection: $syncDraft.autoSyncIntervalUnit) {
                            ForEach(SyncIntervalUnit.allCases, id: \.self) { unit in
                                Text(unit.title).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }
                Toggle(L10n.t("Sync on unlock"), isOn: $syncDraft.autoSyncOnUnlock)
                Picker(L10n.t("Conflict strategy"), selection: $syncDraft.conflictStrategy) {
                    ForEach(SyncSettingsConflictStrategy.allCases, id: \.self) { strategy in
                        Text(strategy.title).tag(strategy)
                    }
                }
                Toggle(L10n.t("Sync master key metadata"), isOn: $syncDraft.syncMasterKey)
                LabeledContent(L10n.t("Device"), value: syncDraft.deviceId)
                LabeledContent(L10n.t("Revision"), value: "\(syncDraft.lastSyncRevision)")
                Button(L10n.t("Save Sync Settings")) {
                    syncDraft.autoSyncIntervalMinutes = syncDraft.autoSyncIntervalValue.toIntervalMinutes(
                        unit: syncDraft.autoSyncIntervalUnit
                    )
                    store.updateSyncSettings(syncDraft)
                }
            }

            if !syncDraft.logs.isEmpty {
                Section(L10n.t("Recent Logs")) {
                    ForEach(syncDraft.logs.prefix(8), id: \.timestamp) { log in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(log.level.uppercased())
                                    .font(.caption.bold())
                                Spacer()
                                Text(log.timestamp, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(log.message.isEmpty ? "-" : L10n.status(log.message))
                                .font(.callout)
                        }
                    }
                }
            }

            Section(L10n.t("Danger Zone")) {
                Text(L10n.t("This clears all entries, categories, tags, and vault security settings. Enter the master password you created to confirm."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(L10n.t("Clear Data"), role: .destructive) {
                    clearDataPassword = ""
                    clearDataError = nil
                    isPresentingClearData = true
                }
            }

            LabeledContent(L10n.t("Sync"), value: L10n.status(store.syncStatus))
            LabeledContent(L10n.t("Backup"), value: L10n.status(store.lastBackupStatus))
            if let statusMessage = store.statusMessage {
                LabeledContent(L10n.t("Vault"), value: L10n.status(statusMessage))
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
        .onAppear {
            totpSecret = store.totpSecret
            syncDraft = store.syncSettings
            refreshBiometricState()
        }
        .sheet(isPresented: $isPresentingBiometricSetup, onDismiss: {
            biometricPassword = ""
            refreshBiometricState()
        }) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.t("Enable Touch ID Unlock?"))
                    .font(.title2)
                Text(L10n.t("Enter your master password to enable Touch ID unlock."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                SecureField(L10n.t("Master password"), text: $biometricPassword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(enableBiometricUnlock)
                if let biometricError {
                    Text(L10n.status(biometricError))
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if isSavingBiometricCredential {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.t("Enabling Touch ID unlock..."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button(L10n.t("Cancel")) {
                        biometricPassword = ""
                        isPresentingBiometricSetup = false
                    }
                    .disabled(isSavingBiometricCredential)
                    Button(L10n.t("Enable"), action: enableBiometricUnlock)
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            isSavingBiometricCredential ||
                                biometricPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
            .padding()
            .frame(width: 460)
        }
        .sheet(isPresented: $isPresentingClearData) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.t("Clear Data"))
                    .font(.title2)
                Text(L10n.t("This clears all entries, categories, tags, and vault security settings. This does not change the master password."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                SecureField(L10n.t("Master password"), text: $clearDataPassword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(clearData)
                if let clearDataError {
                    Text(clearDataError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button(L10n.t("Cancel")) {
                        isPresentingClearData = false
                    }
                    Button(L10n.t("Clear Data"), role: .destructive, action: clearData)
                        .disabled(clearDataPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
            .frame(width: 460)
        }
    }

    private func refreshBiometricState() {
        setBiometricState(biometricCredentialStore.hasSavedCredential())
    }

    private var idleAutoLockMinutesBinding: Binding<Int> {
        Binding(
            get: { preferences.idleAutoLockMinutes },
            set: { preferences.idleAutoLockMinutes = max(0, min($0, 240)) }
        )
    }

    private func setBiometricState(_ enabled: Bool) {
        isBiometricUnlockEnabled = enabled
    }

    private func setBiometricUnlockEnabled(_ enabled: Bool) {
        biometricMessage = nil
        biometricError = nil
        if enabled {
            guard biometricCredentialStore.canAuthenticate() else {
                setBiometricState(false)
                biometricError = L10n.t("Touch ID unlock is not available on this Mac.")
                return
            }
            biometricPassword = ""
            isPresentingBiometricSetup = true
        } else {
            biometricCredentialStore.clear()
            setBiometricState(false)
            biometricMessage = "Touch ID unlock is disabled."
        }
    }

    private func enableBiometricUnlock() {
        let password = biometricPassword
        guard !isSavingBiometricCredential else { return }
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            biometricError = L10n.t("Value is required.")
            return
        }
        guard store.verifyMasterPassword(password) else {
            biometricError = store.statusMessage ?? L10n.t("Vault authentication failed.")
            return
        }

        Task {
            await saveBiometricPassword(password)
        }
    }

    @MainActor
    private func saveBiometricPassword(_ password: String) async {
        isSavingBiometricCredential = true
        defer { isSavingBiometricCredential = false }
        do {
            try await biometricCredentialStore.savePassword(
                password,
                reason: L10n.t("Enable Touch ID unlock for Password Manager.")
            )
            biometricPassword = ""
            biometricError = nil
            biometricMessage = "Touch ID unlock is enabled."
            setBiometricState(true)
            isPresentingBiometricSetup = false
        } catch {
            biometricError = error.localizedDescription
            setBiometricState(biometricCredentialStore.hasSavedCredential())
        }
    }

    private func clearData() {
        guard !clearDataPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearDataError = L10n.t("Value is required.")
            return
        }
        if store.clearAllData(password: clearDataPassword) {
            biometricCredentialStore.clear()
            setBiometricState(false)
            totpSecret = ""
            clearDataPassword = ""
            clearDataError = nil
            isPresentingClearData = false
        } else {
            clearDataError = store.statusMessage ?? L10n.t("Operation failed.")
        }
    }
}
