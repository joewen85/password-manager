import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("AutoSyncSchedulePolicy")
struct AutoSyncSchedulePolicyTests {
    @Test("Interval sync waits until configured seconds elapse")
    func intervalSyncWaitsUntilConfiguredSecondsElapse() {
        let now = Date(timeIntervalSince1970: 1_000)
        var settings = configuredSettings()
        settings.autoSyncEnabled = true
        settings.autoSyncIntervalValue = 30
        settings.autoSyncIntervalUnit = .seconds
        settings.lastSyncAt = now.addingTimeInterval(-29)

        var policy = AutoSyncSchedulePolicy(
            settings: settings,
            isUnlocked: true,
            syncStatus: "Ready",
            lastAutoSyncAttemptAt: nil
        )
        #expect(!policy.shouldRunIntervalSync(now: now))

        settings.lastSyncAt = now.addingTimeInterval(-30)
        policy.settings = settings
        #expect(policy.shouldRunIntervalSync(now: now))
    }

    @Test("Interval sync supports minute units")
    func intervalSyncSupportsMinuteUnits() {
        let now = Date(timeIntervalSince1970: 2_000)
        var settings = configuredSettings()
        settings.autoSyncEnabled = true
        settings.autoSyncIntervalValue = 2
        settings.autoSyncIntervalUnit = .minutes
        settings.lastSyncAt = now.addingTimeInterval(-119)

        var policy = AutoSyncSchedulePolicy(
            settings: settings,
            isUnlocked: true,
            syncStatus: "Ready",
            lastAutoSyncAttemptAt: nil
        )
        #expect(!policy.shouldRunIntervalSync(now: now))

        settings.lastSyncAt = now.addingTimeInterval(-120)
        policy.settings = settings
        #expect(policy.shouldRunIntervalSync(now: now))
    }

    @Test("Interval sync uses last attempt to avoid repeated timer triggers")
    func intervalSyncUsesLastAttemptToAvoidRepeatedTimerTriggers() {
        let now = Date(timeIntervalSince1970: 3_000)
        var settings = configuredSettings()
        settings.autoSyncEnabled = true
        settings.autoSyncIntervalValue = 30
        settings.autoSyncIntervalUnit = .seconds
        settings.lastSyncAt = now.addingTimeInterval(-300)

        let policy = AutoSyncSchedulePolicy(
            settings: settings,
            isUnlocked: true,
            syncStatus: "Ready",
            lastAutoSyncAttemptAt: now.addingTimeInterval(-5)
        )

        #expect(!policy.shouldRunIntervalSync(now: now))
    }

    @Test("Interval sync requires unlocked configured idle state")
    func intervalSyncRequiresUnlockedConfiguredIdleState() {
        let now = Date(timeIntervalSince1970: 4_000)
        var settings = configuredSettings()
        settings.autoSyncEnabled = true
        settings.autoSyncIntervalValue = 1
        settings.autoSyncIntervalUnit = .seconds
        settings.lastSyncAt = now.addingTimeInterval(-60)

        #expect(!policy(settings: settings, isUnlocked: false).shouldRunIntervalSync(now: now))

        settings.providerType = .none
        #expect(!policy(settings: settings).shouldRunIntervalSync(now: now))

        settings.providerType = .webdav
        #expect(!policy(settings: settings, syncStatus: AutoSyncSchedulePolicy.syncingStatus).shouldRunIntervalSync(now: now))

        settings.autoSyncEnabled = false
        #expect(!policy(settings: settings).shouldRunIntervalSync(now: now))
    }

    @Test("Unlock sync triggers once per unlock when enabled")
    func unlockSyncTriggersOncePerUnlockWhenEnabled() {
        var settings = configuredSettings()
        settings.autoSyncOnUnlock = true
        let policy = AutoSyncSchedulePolicy(
            settings: settings,
            isUnlocked: true,
            syncStatus: "Ready",
            lastAutoSyncAttemptAt: nil
        )

        #expect(policy.shouldSyncOnUnlock(hasTriggeredForCurrentUnlock: false))
        #expect(!policy.shouldSyncOnUnlock(hasTriggeredForCurrentUnlock: true))
    }

    @Test("Auto sync checks remote without local changes")
    func autoSyncChecksRemoteWithoutLocalChanges() {
        var settings = configuredSettings()
        settings.autoSyncEnabled = true
        settings.autoSyncOnUnlock = true
        settings.hasLocalChanges = false
        let autoSyncPolicy = policy(settings: settings)

        #expect(autoSyncPolicy.shouldSyncOnUnlock(hasTriggeredForCurrentUnlock: false))
        #expect(autoSyncPolicy.shouldRunIntervalSync(now: Date(timeIntervalSince1970: 5_000)))
    }

    private func configuredSettings() -> SyncSettings {
        var settings = SyncSettings.defaults(deviceId: "device-1")
        settings.providerType = .webdav
        settings.webdavUrl = "https://dav.example.com"
        settings.webdavUsername = "alice"
        settings.webdavPassword = "secret"
        settings.hasLocalChanges = true
        return settings
    }

    private func policy(
        settings: SyncSettings,
        isUnlocked: Bool = true,
        syncStatus: String = "Ready",
        lastAutoSyncAttemptAt: Date? = nil
    ) -> AutoSyncSchedulePolicy {
        AutoSyncSchedulePolicy(
            settings: settings,
            isUnlocked: isUnlocked,
            syncStatus: syncStatus,
            lastAutoSyncAttemptAt: lastAutoSyncAttemptAt
        )
    }
}
