import Foundation
import Testing
@testable import PasswordManagerMacOSApp

@Suite("L10n", .serialized)
struct L10nTests {
    @Test("Language override returns Simplified Chinese strings")
    func languageOverrideReturnsSimplifiedChineseStrings() {
        UserDefaults.standard.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppPreferences.languageStorageKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppPreferences.languageStorageKey)
        }

        #expect(L10n.t("Sync") == "同步")
        #expect(L10n.t("Language") == "语言")
    }

    @Test("Field reference UI and status strings are localized")
    func fieldReferenceStringsAreLocalized() {
        UserDefaults.standard.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppPreferences.languageStorageKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppPreferences.languageStorageKey)
        }

        #expect(L10n.t("Field Reference") == "字段关联")
        #expect(L10n.t("Select Target Field") == "选择目标字段")
        #expect(L10n.tf("Target: %@ / %@", "账号", "邮箱") == "目标：账号 / 邮箱")
        #expect(L10n.status("Field reference requires a target category and target text field.") == "字段关联需要选择目标分类和目标文本字段。")
        #expect(L10n.status("Field reference configuration needs repair.") == "字段关联配置需要修复。")
    }

    @Test("System default follows Simplified Chinese system preference")
    func systemDefaultFollowsSimplifiedChineseSystemPreference() {
        let originalLanguages = UserDefaults.standard.object(forKey: "AppleLanguages")
        UserDefaults.standard.set(AppLanguage.system.rawValue, forKey: AppPreferences.languageStorageKey)
        UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        defer {
            UserDefaults.standard.removeObject(forKey: AppPreferences.languageStorageKey)
            if let originalLanguages {
                UserDefaults.standard.set(originalLanguages, forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
        }

        #expect(L10n.t("Sync") == "同步")
        #expect(L10n.t("Language") == "语言")
    }

    @Test("System default follows English system preference")
    func systemDefaultFollowsEnglishSystemPreference() {
        let originalLanguages = UserDefaults.standard.object(forKey: "AppleLanguages")
        UserDefaults.standard.set(AppLanguage.system.rawValue, forKey: AppPreferences.languageStorageKey)
        UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        defer {
            UserDefaults.standard.removeObject(forKey: AppPreferences.languageStorageKey)
            if let originalLanguages {
                UserDefaults.standard.set(originalLanguages, forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
        }

        #expect(L10n.t("Sync") == "Sync")
        #expect(L10n.t("Language") == "Language")
    }
}
