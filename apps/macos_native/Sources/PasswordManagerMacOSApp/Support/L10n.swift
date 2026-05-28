import Foundation

enum L10n {
    private static let resourceBundleName = "PasswordManagerMacOS_PasswordManagerMacOSApp.bundle"
    private static let resolvedResourceBundle: Bundle? = Self.resolveResourceBundle()

    static func t(_ key: String) -> String {
        NSLocalizedString(key, bundle: localizationBundle, comment: "")
    }

    static func tf(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: locale, arguments: arguments)
    }

    static var locale: Locale {
        if let identifier = languageOverride.localeIdentifier {
            return Locale(identifier: identifier)
        }
        return .autoupdatingCurrent
    }

    private static var localizationBundle: Bundle {
        guard let bundle = resourceBundle else {
            return .main
        }

        guard let lprojName = selectedProjectName(in: bundle),
              let path = localizedProjectPath(for: lprojName, in: bundle),
              let localizedBundle = Bundle(path: path) else {
            return bundle
        }
        return localizedBundle
    }

    private static var languageOverride: AppLanguage {
        UserDefaults.standard.string(forKey: AppPreferences.languageStorageKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    private static var resourceBundle: Bundle? {
        resolvedResourceBundle
    }

    private static func resolveResourceBundle() -> Bundle? {
        for candidateURL in resourceBundleURLs {
            if let bundle = Bundle(url: candidateURL) {
                return bundle
            }
        }

        return findBuildResourceBundle()
    }

    private static var resourceBundleURLs: [URL] {
        var urls: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent(resourceBundleName))
        }

        urls.append(Bundle.main.bundleURL.appendingPathComponent(resourceBundleName))

        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            urls.append(executableDirectory.appendingPathComponent(resourceBundleName))
        }

        return urls
    }

    private static func findBuildResourceBundle() -> Bundle? {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // PasswordManagerMacOSApp
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // macos_native
        let buildRoot = packageRoot.appendingPathComponent(".build")

        guard let enumerator = FileManager.default.enumerator(
            at: buildRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            if url.lastPathComponent == resourceBundleName {
                return Bundle(url: url)
            }
        }

        return nil
    }

    private static func localizedProjectPath(for lprojName: String, in bundle: Bundle) -> String? {
        if let exactPath = bundle.path(forResource: lprojName, ofType: "lproj") {
            return exactPath
        }

        return bundle.urls(forResourcesWithExtension: "lproj", subdirectory: nil)?
            .first { $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(lprojName) == .orderedSame }?
            .path
    }

    private static func selectedProjectName(in bundle: Bundle) -> String? {
        if let overrideName = languageOverride.lprojName {
            return overrideName
        }

        let availableNames = localizedProjectNames(in: bundle)
        guard !availableNames.isEmpty else {
            return nil
        }

        return Bundle.preferredLocalizations(
            from: availableNames,
            forPreferences: systemLanguagePreferences
        ).first
    }

    private static func localizedProjectNames(in bundle: Bundle) -> [String] {
        bundle.urls(forResourcesWithExtension: "lproj", subdirectory: nil)?
            .map { $0.deletingPathExtension().lastPathComponent } ?? []
    }

    private static var systemLanguagePreferences: [String] {
        if let appleLanguages = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String],
           !appleLanguages.isEmpty {
            return appleLanguages
        }

        return Locale.preferredLanguages
    }

    static func status(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return message }

        switch trimmed {
        case "Not configured",
             "No backup has run",
             "Master password is empty or confirmation does not match.",
             "Vault initialized and encrypted locally.",
             "No vault has been initialized.",
             "2FA secret is not configured.",
             "2FA code is invalid.",
             "Unlocking vault...",
             "Vault unlocked.",
             "Vault authentication failed.",
             "Category already exists.",
             "Category added.",
             "Category updated.",
             "Category not found.",
             "Category deleted.",
             "Tag already exists.",
             "Tag added.",
             "Tag updated.",
             "Tag not found.",
             "Tag deleted.",
             "Value is required.",
             "Unlock the vault before clearing data.",
             "Vault data cleared.",
             "Unlock the vault before running backup.",
             "Unlock the vault before restoring backup.",
             "Unlock the vault before exporting.",
             "Unlock the vault before importing.",
             "Configure a sync provider before syncing.",
             "Unlock the vault before syncing.",
             "Syncing...",
             "Sync started.",
             "Sync settings saved.",
             "Encrypted vault found.",
             "Sync complete.",
             "Sync failed",
             "Import complete.",
             "Encrypted vault payload is invalid.",
             "Decrypted vault payload is not valid UTF-8.",
             "Remote sync payload is invalid.",
             "Touch ID unlock is not available on this Mac.",
             "Touch ID authentication failed.",
             "Touch ID unlock has not been enabled.",
             "Stored Touch ID credential is invalid.",
             "Could not create Touch ID Keychain access control.",
             "Enabling Touch ID unlock...",
             "Touch ID failed 3 times. Enter the master password to unlock.",
             "Idle auto-lock",
             "Lock the vault after the app is idle for the selected number of minutes. Set to Off to disable.",
             "Lock the vault after the app is idle for the selected number of minutes. Enter 0 to disable.",
             "Off":
            return t(trimmed)
        default:
            break
        }

        if let suffix = trimmed.suffix(after: "Configured: ") {
            return tf("Configured: %@", suffix)
        }
        if let suffix = trimmed.suffix(after: "Backup saved: ") {
            return tf("Backup saved: %@", suffix)
        }
        if let suffix = trimmed.suffix(after: "Restored backup: ") {
            return tf("Restored backup: %@", suffix)
        }
        if let suffix = trimmed.suffix(after: "Export saved: ") {
            return tf("Export saved: %@", suffix)
        }
        if let suffix = trimmed.suffix(after: "Export ready: ") {
            return tf("Export ready: %@", suffix)
        }
        if let suffix = trimmed.suffix(after: "Entry export saved: ") {
            return tf("Entry export saved: %@", suffix)
        }
        if let suffix = trimmed.suffix(after: "Entry export ready: ") {
            return tf("Entry export ready: %@", suffix)
        }
        if let suffix = trimmed.suffix(after: "Category export saved: ") {
            return tf("Category export saved: %@", suffix)
        }
        if let suffix = trimmed.suffix(after: "Category export ready: ") {
            return tf("Category export ready: %@", suffix)
        }
        if let suffix = trimmed.suffix(after: "Secure random generation failed with status "),
           let status = Int(suffix.dropLastDot()) {
            return tf("Secure random generation failed with status %d.", status)
        }
        if let suffix = trimmed.suffix(after: "PBKDF2 key derivation failed with status "),
           let status = Int(suffix.dropLastDot()) {
            return tf("PBKDF2 key derivation failed with status %d.", status)
        }
        if let suffix = trimmed.suffix(after: "Sync download failed with status "),
           let status = Int(suffix.dropLastDot()) {
            return tf("Sync download failed with status %d.", status)
        }
        if let suffix = trimmed.suffix(after: "Sync upload failed with status "),
           let status = Int(suffix.dropLastDot()) {
            return tf("Sync upload failed with status %d.", status)
        }
        if let suffix = trimmed.suffix(after: "Keychain operation failed with status "),
           let status = Int(suffix.dropLastDot()) {
            return tf("Keychain operation failed with status %d.", status)
        }
        if let suffix = trimmed.suffix(after: "Imported "),
           let countText = suffix.removingSuffix(" active entries."),
           let count = Int(countText) {
            return tf("Imported %d active entries.", count)
        }
        if let counts = importedCounts(from: trimmed) {
            return tf("Imported %d created, %d updated, %d skipped.", counts.created, counts.updated, counts.skipped)
        }
        if let sync = syncResult(from: trimmed) {
            return tf(
                "Synced %d items, %d conflicts, %d deletes, revision %d.",
                sync.total,
                sync.conflicts,
                sync.deletes,
                sync.revision
            )
        }
        if let dateText = trimmed.suffix(after: "Vault saved at ") {
            return tf("Vault saved at %@", dateText)
        }
        if let value = Int(trimmed.replacingOccurrences(of: " min", with: "")) {
            return tf("%d min", value)
        }

        return message
    }

    private static func importedCounts(from message: String) -> (created: Int, updated: Int, skipped: Int)? {
        guard message.hasPrefix("Imported "),
              message.hasSuffix(" skipped.") else {
            return nil
        }
        let values = integers(in: message)
        guard values.count == 3 else { return nil }
        let created = values[0]
        let updated = values[1]
        let skipped = values[2]
        return (created, updated, skipped)
    }

    private static func syncResult(from message: String) -> (total: Int, conflicts: Int, deletes: Int, revision: Int)? {
        guard message.hasPrefix("Synced "),
              message.hasSuffix(".") else {
            return nil
        }
        let values = integers(in: message)
        guard values.count == 4 else { return nil }
        let total = values[0]
        let conflicts = values[1]
        let deletes = values[2]
        let revision = values[3]
        return (total, conflicts, deletes, revision)
    }

    private static func integers(in message: String) -> [Int] {
        message
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { $0.isEmpty ? nil : Int($0) }
    }
}

private extension String {
    func suffix(after prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }

    func prefix(before suffix: String) -> String? {
        guard let range = range(of: suffix) else { return nil }
        return String(self[..<range.lowerBound])
    }

    func removingSuffix(_ suffix: String) -> String? {
        guard hasSuffix(suffix) else { return nil }
        return String(dropLast(suffix.count))
    }

    func dropLastDot() -> String {
        hasSuffix(".") ? String(dropLast()) : self
    }
}
