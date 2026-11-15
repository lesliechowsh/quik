import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case german = "de"
    case french = "fr"
    case japanese = "ja"

    var id: String { rawValue }

    static let storageKey = "appLanguage"

    // Read every call, not once into a static, so a test or `defaults write`
    // changes the language without relaunching.
    static var stored: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: storageKey) else { return .system }
        return AppLanguage(rawValue: raw) ?? .system
    }

    static func select(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: storageKey)
    }

    static var systemMatch: AppLanguage {
        switch Bundle.main.preferredLocalizations.first {
        case "zh-Hans": return .simplifiedChinese
        case "en": return .english
        case "de": return .german
        case "fr": return .french
        case "ja": return .japanese
        default: return .english
        }
    }

    static var effective: AppLanguage {
        stored == .system ? systemMatch : stored
    }

    var isSystem: Bool { self == .system }

    var endonym: String {
        switch self {
        case .system: return Self.systemMatch.endonym
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .japanese: return "日本語"
        }
    }

    var menuTitle: String {
        self == .system ? Copy.followSystemLanguage() : endonym
    }
}
