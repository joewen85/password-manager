package life.devops.passwordmanager.sync

import java.time.Instant

class AutoSyncSchedulePolicy(
    private val settings: SyncSettings,
    private val isUnlocked: Boolean,
    private val syncStatus: String,
    private val lastAutoSyncAttemptAt: Instant?,
) {
    private val canCheckRemoteSync: Boolean
        get() = isUnlocked &&
            settings.providerType != SyncProviderType.NONE &&
            syncStatus != SyncingStatus

    fun shouldSyncOnUnlock(hasTriggeredForCurrentUnlock: Boolean): Boolean =
        !hasTriggeredForCurrentUnlock &&
            settings.autoSyncOnUnlock &&
            canCheckRemoteSync

    fun shouldRunIntervalSync(now: Instant): Boolean {
        if (!canCheckRemoteSync || !settings.autoSyncEnabled) {
            return false
        }
        val reference = listOfNotNull(lastAutoSyncAttemptAt, settings.lastSyncAt).maxOrNull()
            ?: return true
        return now.toEpochMilli() - reference.toEpochMilli() >= intervalMillis(settings)
    }

    companion object {
        const val SyncingStatus = "Syncing..."

        fun intervalMillis(settings: SyncSettings): Long {
            val value = settings.autoSyncIntervalValue.coerceAtLeast(1).toLong()
            val unitMillis = when (settings.autoSyncIntervalUnit) {
                SyncIntervalUnit.SECONDS -> 1_000L
                SyncIntervalUnit.MINUTES -> 60_000L
            }
            return value * unitMillis
        }
    }
}
