import Foundation
import Observation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            L10n.t("System Default")
        case .english:
            "English"
        case .simplifiedChinese:
            "简体中文"
        }
    }

    var localeIdentifier: String? {
        switch self {
        case .system:
            nil
        case .english:
            "en"
        case .simplifiedChinese:
            "zh-Hans"
        }
    }

    var lprojName: String? {
        switch self {
        case .system:
            nil
        case .english:
            "en"
        case .simplifiedChinese:
            "zh-Hans"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            L10n.t("System Default")
        case .light:
            L10n.t("Light")
        case .dark:
            L10n.t("Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

@Observable
final class AppPreferences {
    static let languageStorageKey = "app.language"
    static let appearanceStorageKey = "app.appearance"
    static let idleAutoLockMinutesStorageKey = "app.idleAutoLockMinutes"

    private let defaults: UserDefaults

    var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Self.languageStorageKey)
        }
    }

    var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Self.appearanceStorageKey)
        }
    }

    var idleAutoLockMinutes: Int {
        didSet {
            defaults.set(idleAutoLockMinutes, forKey: Self.idleAutoLockMinutesStorageKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = Self.loadLanguage(from: defaults)
        appearance = Self.loadAppearance(from: defaults)
        idleAutoLockMinutes = Self.loadIdleAutoLockMinutes(from: defaults)
    }

    var locale: Locale {
        if let identifier = language.localeIdentifier {
            return Locale(identifier: identifier)
        }
        return .autoupdatingCurrent
    }

    var colorScheme: ColorScheme? {
        appearance.colorScheme
    }

    private static func loadLanguage(from defaults: UserDefaults) -> AppLanguage {
        defaults.string(forKey: languageStorageKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    private static func loadAppearance(from defaults: UserDefaults) -> AppAppearance {
        defaults.string(forKey: appearanceStorageKey)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    private static func loadIdleAutoLockMinutes(from defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: idleAutoLockMinutesStorageKey) != nil else {
            return 0
        }
        return max(0, min(defaults.integer(forKey: idleAutoLockMinutesStorageKey), 240))
    }
}
