import LocalAuthentication
import SwiftUI

struct UnlockView: View {
    @Bindable var store: VaultStore
    @State private var password = ""
    @State private var confirmation = ""
    @State private var totpCode = ""
    @State private var errorMessage: String?
    @State private var isAuthenticatingWithBiometrics = false
    @State private var biometricFailureCount = 0
    @State private var hasAutoPromptedBiometrics = false
    @State private var isPasswordFallbackRequired = false

    private let biometricCredentialStore = MacBiometricCredentialStore()
    private let maxBiometricFailures = 3

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.tint)

            Text(store.hasMasterKey ? L10n.t("Unlock Vault") : L10n.t("Initialize Vault"))
                .font(.largeTitle.bold())

            Text(store.hasMasterKey ? L10n.t("Enter the master password to continue.") : L10n.t("Set a master password for the local native vault."))
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                SecureField(L10n.t("Master password"), text: $password)
                    .textFieldStyle(.roundedBorder)

                if !store.hasMasterKey {
                    SecureField(L10n.t("Confirm master password"), text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                }

                if store.requireTotp && store.hasMasterKey {
                    TextField(L10n.t("2FA code"), text: $totpCode)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .frame(maxWidth: 360)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if let statusMessage = store.statusMessage {
                Text(L10n.status(statusMessage))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button(store.hasMasterKey ? L10n.t("Unlock") : L10n.t("Create Vault")) {
                submit()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

            if store.hasMasterKey,
               biometricCredentialStore.hasSavedCredential(),
               biometricCredentialStore.canAuthenticate() {
                Button(L10n.t("Unlock with Touch ID")) {
                    unlockWithBiometrics(isAutomatic: false)
                }
                .disabled(isAuthenticatingWithBiometrics || isPasswordFallbackRequired)
            }
        }
        .padding(40)
        .onAppear(perform: autoPromptBiometricsIfNeeded)
        .onChange(of: store.isUnlocked) { _, _ in
            resetBiometricPromptState()
        }
    }

    private func submit() {
        let success = store.hasMasterKey
            ? store.unlock(password: password, totpCode: totpCode)
            : store.setupMasterPassword(password, confirmation: confirmation)

        if success {
            errorMessage = nil
            password = ""
            confirmation = ""
            totpCode = ""
            resetBiometricPromptState()
        } else {
            errorMessage = L10n.t("Operation failed. Check the password, confirmation, and 2FA code.")
        }
    }

    private var canUseBiometrics: Bool {
        store.hasMasterKey &&
            biometricCredentialStore.hasSavedCredential() &&
            biometricCredentialStore.canAuthenticate()
    }

    private func autoPromptBiometricsIfNeeded() {
        guard canUseBiometrics,
              !store.isUnlocked,
              !hasAutoPromptedBiometrics,
              !isPasswordFallbackRequired else {
            return
        }

        hasAutoPromptedBiometrics = true
        unlockWithBiometrics(isAutomatic: true)
    }

    private func unlockWithBiometrics(isAutomatic: Bool) {
        guard canUseBiometrics,
              !isAuthenticatingWithBiometrics,
              !isPasswordFallbackRequired else {
            return
        }

        isAuthenticatingWithBiometrics = true
        Task {
            do {
                let savedPassword = try await biometricCredentialStore.readPassword(
                    reason: L10n.t("Unlock Password Manager.")
                )
                await MainActor.run {
                    errorMessage = L10n.t("Unlocking vault...")
                }
                let code = await MainActor.run { totpCode }
                let success = await store.prepareBiometricUnlock(password: savedPassword, totpCode: code)
                await MainActor.run {
                    if success {
                        errorMessage = nil
                        password = ""
                        confirmation = ""
                        totpCode = ""
                        resetBiometricPromptState()
                    } else {
                        errorMessage = L10n.t("Operation failed. Check the password, confirmation, and 2FA code.")
                    }
                    isAuthenticatingWithBiometrics = false
                }
            } catch {
                await MainActor.run {
                    isAuthenticatingWithBiometrics = false
                    let shouldRetry = recordBiometricFailure(error)
                    if isAutomatic, shouldRetry {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            unlockWithBiometrics(isAutomatic: true)
                        }
                    }
                }
            }
        }
    }

    @discardableResult
    private func recordBiometricFailure(_ error: Error) -> Bool {
        guard isRetryableBiometricFailure(error) else {
            isPasswordFallbackRequired = true
            errorMessage = L10n.status(error.localizedDescription)
            return false
        }

        biometricFailureCount += 1
        if biometricFailureCount >= maxBiometricFailures {
            isPasswordFallbackRequired = true
            errorMessage = L10n.t("Touch ID failed 3 times. Enter the master password to unlock.")
            return false
        } else {
            errorMessage = L10n.status(error.localizedDescription)
            return true
        }
    }

    private func isRetryableBiometricFailure(_ error: Error) -> Bool {
        guard let laError = error as? LAError else {
            return false
        }
        return laError.code == .authenticationFailed
    }

    private func resetBiometricPromptState() {
        guard store.isUnlocked else {
            return
        }
        biometricFailureCount = 0
        hasAutoPromptedBiometrics = false
        isPasswordFallbackRequired = false
    }
}
