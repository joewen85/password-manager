import AppKit
import SwiftUI

@main
struct PasswordManagerMacOSApp: App {
    @State private var vaultStore = VaultStore()
    @State private var appPreferences = AppPreferences()
    @State private var lastUserActivityAt = Date()
    @State private var eventMonitor: Any?

    private let idleLockTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup(L10n.t("Password Manager"), id: "main") {
            ContentView(store: vaultStore)
                .frame(minWidth: 1080, minHeight: 680)
                .environment(\.locale, appPreferences.locale)
                .preferredColorScheme(appPreferences.colorScheme)
                .onAppear {
                    activateMainWindow()
                    installActivityMonitorIfNeeded()
                    markUserActivity()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        activateMainWindow()
                    }
                }
                .onReceive(idleLockTimer) { now in
                    lockVaultIfIdle(now: now)
                }
        }
        .commands {
            CommandMenu(L10n.t("Vault")) {
                Button(L10n.t("Lock Vault")) {
                    vaultStore.lock()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!vaultStore.isUnlocked)
            }
        }

        Settings {
            SettingsView(store: vaultStore, preferences: appPreferences)
                .environment(\.locale, appPreferences.locale)
                .preferredColorScheme(appPreferences.colorScheme)
        }
    }

    @MainActor
    private func activateMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.windows.forEach { $0.orderFrontRegardless() }
        NSApp.windows.first?.makeMain()
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func installActivityMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel
        ]) { event in
            markUserActivity()
            return event
        }
    }

    @MainActor
    private func markUserActivity() {
        lastUserActivityAt = Date()
    }

    @MainActor
    private func lockVaultIfIdle(now: Date) {
        let idleMinutes = appPreferences.idleAutoLockMinutes
        guard idleMinutes > 0, vaultStore.isUnlocked else { return }

        let idleSeconds = TimeInterval(idleMinutes * 60)
        guard now.timeIntervalSince(lastUserActivityAt) >= idleSeconds else { return }

        vaultStore.lock()
        markUserActivity()
    }
}
