package life.devops.passwordmanager

import androidx.appcompat.app.AppCompatDelegate
import org.junit.Assert.assertEquals
import org.junit.Test

class AppUiPreferencesTest {
    @Test
    fun unknownOrMissingPreferencesFallBackToSystem() {
        assertEquals(AppLanguage.SYSTEM, AppLanguage.fromPreference(null))
        assertEquals(AppLanguage.SYSTEM, AppLanguage.fromPreference("unknown"))
        assertEquals(AppAppearance.SYSTEM, AppAppearance.fromPreference(null))
        assertEquals(AppAppearance.SYSTEM, AppAppearance.fromPreference("unknown"))
    }

    @Test
    fun languageSelectionMapsToSupportedAppLocales() {
        assertEquals("", AppLanguage.SYSTEM.toLocaleListCompat().toLanguageTags())
        assertEquals("en", AppLanguage.ENGLISH.toLocaleListCompat().toLanguageTags())
        assertEquals("zh-CN", AppLanguage.SIMPLIFIED_CHINESE.toLocaleListCompat().toLanguageTags())
        assertEquals(AppLanguage.SIMPLIFIED_CHINESE, AppLanguage.fromLocaleTags("zh-CN"))
        assertEquals(AppLanguage.ENGLISH, AppLanguage.fromLocaleTags("en-US"))
        assertEquals(AppLanguage.SYSTEM, AppLanguage.fromLocaleTags("fr-FR"))
    }

    @Test
    fun appearanceSelectionMapsToAppCompatModes() {
        assertEquals(AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM, AppAppearance.SYSTEM.nightMode)
        assertEquals(AppCompatDelegate.MODE_NIGHT_NO, AppAppearance.LIGHT.nightMode)
        assertEquals(AppCompatDelegate.MODE_NIGHT_YES, AppAppearance.DARK.nightMode)
    }
}
