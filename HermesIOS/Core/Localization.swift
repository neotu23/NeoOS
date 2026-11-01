import Foundation
import Observation

/// Languages the interface can be displayed in.
///
/// French is the source language: every user-facing literal in the code is French, so a French key
/// resolves to itself and the French interface needs no table at all. English and Simplified
/// Chinese live in `en.lproj` and `zh-Hans.lproj` as `Localizable.strings`, keyed by that French text.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case french = "fr"
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// The language named in itself, the way language pickers show it.
    var autonym: String {
        switch self {
        case .french: "Français"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

/// The active translation table, readable from any isolation: views, settings catalogs built as
/// `static let`, and tests. `Localizer` owns it and swaps the whole snapshot at once.
final class LocalizationSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var language: AppLanguage = .french
    private var table: [String: String] = [:]

    var currentLanguage: AppLanguage { lock.withLock { language } }

    func string(_ key: String) -> String {
        lock.withLock { language == .french ? key : (table[key] ?? key) }
    }

    func string(_ key: String, _ arguments: [any CVarArg]) -> String {
        String(format: string(key), arguments: arguments)
    }

    func apply(language: AppLanguage, table: [String: String]) {
        lock.withLock {
            self.language = language
            self.table = table
        }
    }
}

/// Process-wide table behind `L(_:)`. A `let` of a `Sendable` type, so any code can read it.
let localization = LocalizationSnapshot()

/// The language chosen on this device, applied without relaunching.
@MainActor
@Observable
final class Localizer {
    static let shared = Localizer()

    /// Same storage conventions as the other Hermes preferences (`hermes.*` keys in `UserDefaults`).
    static let defaultsKey = "hermes.uiLanguage"

    private(set) var language: AppLanguage

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey).flatMap(AppLanguage.init(rawValue:))
        let language = stored ?? .french
        self.language = language
        localization.apply(language: language, table: Self.loadTable(language))
    }

    func select(_ language: AppLanguage) {
        guard language != self.language else { return }
        self.language = language
        localization.apply(language: language, table: Self.loadTable(language))
        UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
    }

    /// Reads the compiled `.strings` table of one language out of the app bundle.
    private static func loadTable(_ language: AppLanguage) -> [String: String] {
        guard language != .french,
              let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path),
              let url = bundle.url(forResource: "Localizable", withExtension: "strings"),
              let contents = NSDictionary(contentsOf: url) as? [String: String]
        else { return [:] }
        return contents
    }
}

/// Translates a French source sentence into the selected interface language.
///
/// Keys are the French literals themselves, so a missing entry degrades to French text instead of a
/// raw identifier.
func L(_ key: String) -> String {
    localization.string(key)
}

/// A translated sentence carrying `String(format:)` placeholders, e.g. `L("%lld conversations", count)`.
func L(_ key: String, _ arguments: any CVarArg...) -> String {
    localization.string(key, arguments)
}
