import SwiftUI

struct UnlockView: View {
    @Bindable var store: VaultStore
    @State private var password = ""
    @State private var confirmation = ""
    @State private var totpCode = ""
    @State private var errorMessage: String?
    @State private var pendingBiometricPassword = ""
    @State private var isShowingEnableBiometricPrompt = false
    @State private var isAuthenticatingWithBiometrics = false

    private let biometricCredentialStore = iOSBiometricCredentialStore()

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.tint)

            Text(store.hasMasterKey ? "Unlock Vault" : "Initialize Vault")
                .font(.largeTitle.bold())

            Text(store.hasMasterKey ? "Enter the master password to continue." : "Set a master password for the local native vault.")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                SecureField("Master password", text: $password)
                    .textFieldStyle(.roundedBorder)

                if !store.hasMasterKey {
                    SecureField("Confirm master password", text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                }

                if store.requireTotp && store.hasMasterKey {
                    TextField("2FA code", text: $totpCode)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .frame(maxWidth: 360)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if let statusMessage = store.statusMessage {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button(store.hasMasterKey ? "Unlock" : "Create Vault") {
                submit()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

            if store.hasMasterKey,
               biometricCredentialStore.hasSavedCredential(),
               biometricCredentialStore.canAuthenticate() {
                Button("Unlock with Face ID / Touch ID") {
                    unlockWithBiometrics()
                }
                .disabled(isAuthenticatingWithBiometrics)
            }
        }
        .padding(40)
        .alert("Enable Face ID / Touch ID Unlock?", isPresented: $isShowingEnableBiometricPrompt) {
            Button("Enable") {
                enableBiometricUnlock()
            }
            Button("Not Now", role: .cancel) {
                pendingBiometricPassword = ""
            }
        } message: {
            Text("Use this device's biometric authentication instead of entering the master password.")
        }
    }

    private func submit() {
        let enteredPassword = password
        let success = store.hasMasterKey
            ? store.unlock(password: password, totpCode: totpCode)
            : store.setupMasterPassword(password, confirmation: confirmation)

        if success {
            errorMessage = nil
            password = ""
            confirmation = ""
            totpCode = ""
            offerBiometricUnlock(for: enteredPassword)
        } else {
            errorMessage = "Operation failed. Check the password, confirmation, and 2FA code."
        }
    }

    private func offerBiometricUnlock(for password: String) {
        guard store.hasMasterKey,
              !biometricCredentialStore.hasSavedCredential(),
              biometricCredentialStore.canAuthenticate() else {
            return
        }
        pendingBiometricPassword = password
        isShowingEnableBiometricPrompt = true
    }

    private func enableBiometricUnlock() {
        let passwordToSave = pendingBiometricPassword
        pendingBiometricPassword = ""
        Task {
            do {
                try await biometricCredentialStore.savePassword(
                    passwordToSave,
                    reason: "Enable biometric unlock for Password Manager."
                )
                await MainActor.run {
                    errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func unlockWithBiometrics() {
        isAuthenticatingWithBiometrics = true
        Task {
            do {
                let savedPassword = try await biometricCredentialStore.readPassword(
                    reason: "Unlock Password Manager."
                )
                await MainActor.run {
                    let success = store.unlock(password: savedPassword, totpCode: totpCode)
                    if success {
                        errorMessage = nil
                        password = ""
                        confirmation = ""
                        totpCode = ""
                    } else {
                        errorMessage = "Operation failed. Check the password, confirmation, and 2FA code."
                    }
                    isAuthenticatingWithBiometrics = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isAuthenticatingWithBiometrics = false
                }
            }
        }
    }
}
