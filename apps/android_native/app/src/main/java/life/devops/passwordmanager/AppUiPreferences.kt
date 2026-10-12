package life.devops.passwordmanager

import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import java.util.Locale

internal enum class AppLanguage(val preferenceValue: String, val localeTag: String?) {
    SYSTEM("system", null),
    ENGLISH("english", "en"),
    SIMPLIFIED_CHINESE("simplified_chinese", "zh-CN");

    fun toLocaleListCompat(): LocaleListCompat =
        localeTag?.let(LocaleListCompat::forLanguageTags) ?: LocaleListCompat.getEmptyLocaleList()

    companion object {
        fun fromPreference(value: String?): AppLanguage =
            entries.firstOrNull { it.preferenceValue == value } ?: SYSTEM

        fun fromLocaleTags(tags: String?): AppLanguage {
            val language = tags.orEmpty().substringBefore(',').substringBefore('-').lowercase(Locale.ROOT)
            return when (language) {
                "en" -> ENGLISH
                "zh" -> SIMPLIFIED_CHINESE
                else -> SYSTEM
            }
        }
    }
}

internal enum class AppAppearance(val preferenceValue: String, val nightMode: Int) {
    SYSTEM("system", AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM),
    LIGHT("light", AppCompatDelegate.MODE_NIGHT_NO),
    DARK("dark", AppCompatDelegate.MODE_NIGHT_YES);

    companion object {
        fun fromPreference(value: String?): AppAppearance =
            entries.firstOrNull { it.preferenceValue == value } ?: SYSTEM
    }
}
