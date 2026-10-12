import SwiftUI
import Testing
@testable import PasswordManageriOSCore

@Suite("App UI preferences")
struct AppUiPreferencesTests {
    @Test("Unknown preferences resolve to system defaults")
    func unknownPreferencesResolveToSystemDefaults() {
        #expect(AppLanguage.resolve("unknown") == .system)
        #expect(AppAppearance.resolve("unknown") == .system)
        #expect(AppAppearance.system.colorScheme == nil)
    }

    @Test("Language preferences select app locales")
    func languagePreferencesSelectAppLocales() {
        #expect(AppLanguage.english.locale.identifier == "en")
        #expect(AppLanguage.simplifiedChinese.locale.identifier == "zh-Hans")
        #expect(AppLanguage.system.locale.identifier == Locale.autoupdatingCurrent.identifier)
    }

    @Test("Appearance preferences select explicit color schemes")
    func appearancePreferencesSelectColorSchemes() {
        #expect(AppAppearance.light.colorScheme == .light)
        #expect(AppAppearance.dark.colorScheme == .dark)
    }
}
