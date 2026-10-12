import SwiftUI
import Combine

public struct PasswordManageriOSAppRoot: View {
    @State private var vaultStore: VaultStore
    @AppStorage(AppPreferences.languageStorageKey) private var languagePreference = AppLanguage.system.rawValue
    @AppStorage(AppPreferences.appearanceStorageKey) private var appearancePreference = AppAppearance.system.rawValue
    @AppStorage("idle_auto_lock_minutes") private var idleAutoLockMinutes = 0
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastUserActivityAt = Date()
    @State private var lastAutoSyncAttemptAt: Date?
    @State private var lastAutoSyncUnlockState = false

    private let idleLockTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    private let autoSyncTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init() {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-vault") {
            _vaultStore = State(initialValue: DebugUIFixture.makeStore())
            return
        }
        #endif
        _vaultStore = State(initialValue: VaultStore())
    }

    public var body: some View {
        ContentView(store: vaultStore)
            .environment(\.locale, AppLanguage.resolve(languagePreference).locale)
            .preferredColorScheme(AppAppearance.resolve(appearancePreference).colorScheme)
            #if os(iOS)
            .background(KeyboardDismissalView().allowsHitTesting(false))
            #endif
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in markUserActivity() }
            )
            .onReceive(idleLockTimer) { now in
                lockVaultIfIdle(now: now)
            }
            .onReceive(autoSyncTimer) { now in
                runAutoSyncIfNeeded(now: now)
            }
            .onChange(of: vaultStore.isUnlocked) { _, isUnlocked in
                syncOnUnlockIfNeeded(isUnlocked: isUnlocked)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    markUserActivity()
                    runAutoSyncIfNeeded(now: Date())
                }
            }
    }

    private func markUserActivity() {
        lastUserActivityAt = Date()
    }

    private func lockVaultIfIdle(now: Date) {
        guard idleAutoLockMinutes > 0, vaultStore.isUnlocked else { return }
        guard now.timeIntervalSince(lastUserActivityAt) >= TimeInterval(idleAutoLockMinutes * 60) else { return }
        vaultStore.lock()
        markUserActivity()
    }

    private func syncOnUnlockIfNeeded(isUnlocked: Bool) {
        if !isUnlocked {
            lastAutoSyncUnlockState = false
            return
        }

        let policy = autoSyncPolicy
        guard policy.shouldSyncOnUnlock(hasTriggeredForCurrentUnlock: lastAutoSyncUnlockState) else {
            return
        }

        lastAutoSyncUnlockState = true
        lastAutoSyncAttemptAt = Date()
        vaultStore.syncNow()
    }

    private func runAutoSyncIfNeeded(now: Date) {
        guard autoSyncPolicy.shouldRunIntervalSync(now: now) else {
            return
        }

        lastAutoSyncAttemptAt = now
        vaultStore.syncNow()
    }

    private var autoSyncPolicy: AutoSyncSchedulePolicy {
        AutoSyncSchedulePolicy(
            settings: vaultStore.syncSettings,
            isUnlocked: vaultStore.isUnlocked,
            syncStatus: vaultStore.syncStatus,
            lastAutoSyncAttemptAt: lastAutoSyncAttemptAt
        )
    }
}
