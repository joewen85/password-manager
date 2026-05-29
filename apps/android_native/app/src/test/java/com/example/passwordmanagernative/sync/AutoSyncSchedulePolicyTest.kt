package com.example.passwordmanagernative.sync

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AutoSyncSchedulePolicyTest {
    private val now: Instant = Instant.parse("2026-05-28T12:00:00Z")

    @Test
    fun unlockSyncRequiresConfiguredUnlockedProvider() {
        val disabled = AutoSyncSchedulePolicy(
            settings = SyncSettings.defaults().copy(autoSyncOnUnlock = true),
            isUnlocked = true,
            syncStatus = "Ready",
            lastAutoSyncAttemptAt = null,
        )
        val locked = AutoSyncSchedulePolicy(
            settings = configuredSettings().copy(autoSyncOnUnlock = true),
            isUnlocked = false,
            syncStatus = "Ready",
            lastAutoSyncAttemptAt = null,
        )
        val configured = AutoSyncSchedulePolicy(
            settings = configuredSettings().copy(autoSyncOnUnlock = true),
            isUnlocked = true,
            syncStatus = "Ready",
            lastAutoSyncAttemptAt = null,
        )

        assertFalse(disabled.shouldSyncOnUnlock(hasTriggeredForCurrentUnlock = false))
        assertFalse(locked.shouldSyncOnUnlock(hasTriggeredForCurrentUnlock = false))
        assertFalse(configured.shouldSyncOnUnlock(hasTriggeredForCurrentUnlock = true))
        assertTrue(configured.shouldSyncOnUnlock(hasTriggeredForCurrentUnlock = false))
    }

    @Test
    fun intervalSyncRunsImmediatelyWithoutPreviousSync() {
        val policy = AutoSyncSchedulePolicy(
            settings = configuredSettings().copy(autoSyncEnabled = true),
            isUnlocked = true,
            syncStatus = "Ready",
            lastAutoSyncAttemptAt = null,
        )

        assertTrue(policy.shouldRunIntervalSync(now))
    }

    @Test
    fun intervalSyncWaitsForConfiguredIntervalFromLatestReference() {
        val settings = configuredSettings().copy(
            autoSyncEnabled = true,
            autoSyncIntervalValue = 30,
            autoSyncIntervalUnit = SyncIntervalUnit.SECONDS,
            lastSyncAt = now.minusSeconds(60),
        )
        val policy = AutoSyncSchedulePolicy(
            settings = settings,
            isUnlocked = true,
            syncStatus = "Ready",
            lastAutoSyncAttemptAt = now.minusSeconds(10),
        )

        assertFalse(policy.shouldRunIntervalSync(now))
        assertTrue(policy.shouldRunIntervalSync(now.plusSeconds(20)))
    }

    @Test
    fun intervalSyncDoesNotRunWhileSyncing() {
        val policy = AutoSyncSchedulePolicy(
            settings = configuredSettings().copy(autoSyncEnabled = true),
            isUnlocked = true,
            syncStatus = AutoSyncSchedulePolicy.SyncingStatus,
            lastAutoSyncAttemptAt = null,
        )

        assertFalse(policy.shouldRunIntervalSync(now))
    }

    @Test
    fun autoSyncRunsRemoteCheckWithoutLocalChanges() {
        val cleanSettings = configuredSettings().copy(
            autoSyncEnabled = true,
            autoSyncOnUnlock = true,
            hasLocalChanges = false,
        )
        val policy = AutoSyncSchedulePolicy(
            settings = cleanSettings,
            isUnlocked = true,
            syncStatus = "Ready",
            lastAutoSyncAttemptAt = null,
        )

        assertTrue(policy.shouldSyncOnUnlock(hasTriggeredForCurrentUnlock = false))
        assertTrue(policy.shouldRunIntervalSync(now))
    }

    @Test
    fun intervalMillisUsesSelectedUnit() {
        assertEquals(
            30_000L,
            AutoSyncSchedulePolicy.intervalMillis(
                configuredSettings().copy(
                    autoSyncIntervalValue = 30,
                    autoSyncIntervalUnit = SyncIntervalUnit.SECONDS,
                )
            )
        )
        assertEquals(
            300_000L,
            AutoSyncSchedulePolicy.intervalMillis(
                configuredSettings().copy(
                    autoSyncIntervalValue = 5,
                    autoSyncIntervalUnit = SyncIntervalUnit.MINUTES,
                )
            )
        )
    }

    private fun configuredSettings(): SyncSettings =
        SyncSettings.defaults(deviceId = "android-device").copy(
            providerType = SyncProviderType.WEBDAV,
            webdavUrl = "https://dav.example.com",
            webdavPath = "/vault.json",
            hasLocalChanges = true,
        )
}
