import Foundation

struct AutoSyncSchedulePolicy {
    static let syncingStatus = "Syncing..."

    var settings: SyncSettings
    var isUnlocked: Bool
    var syncStatus: String
    var lastAutoSyncAttemptAt: Date?

    var canCheckRemoteSync: Bool {
        isUnlocked &&
            settings.providerType != .none &&
            syncStatus != Self.syncingStatus
    }

    func shouldSyncOnUnlock(hasTriggeredForCurrentUnlock: Bool) -> Bool {
        !hasTriggeredForCurrentUnlock &&
            settings.autoSyncOnUnlock &&
            canCheckRemoteSync
    }

    func shouldRunIntervalSync(now: Date) -> Bool {
        guard canCheckRemoteSync,
              settings.autoSyncEnabled else {
            return false
        }

        let referenceDate = Self.maxDate(lastAutoSyncAttemptAt, settings.lastSyncAt) ?? .distantPast
        return now.timeIntervalSince(referenceDate) >= Self.intervalSeconds(for: settings)
    }

    static func intervalSeconds(for settings: SyncSettings) -> TimeInterval {
        TimeInterval(max(settings.autoSyncIntervalValue, 1)) * intervalUnitMultiplier(settings.autoSyncIntervalUnit)
    }

    private static func intervalUnitMultiplier(_ unit: SyncIntervalUnit) -> TimeInterval {
        switch unit {
        case .seconds: 1
        case .minutes: 60
        }
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.none, .none): nil
        case (.some(let date), .none), (.none, .some(let date)): date
        case (.some(let lhs), .some(let rhs)): max(lhs, rhs)
        }
    }
}
