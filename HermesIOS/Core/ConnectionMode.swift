import Foundation

/// How this device reaches Hermes.
///
/// Direct stays the default: an existing install must keep working untouched after the update, so a
/// missing value resolves to `.direct` rather than to the new mode.
enum ConnectionMode: String, CaseIterable, Identifiable, Sendable {
    case direct
    case cloud

    var id: String { rawValue }

    /// The source-language key; `en`/`zh-Hans` tables provide the other two.
    var label: String {
        switch self {
        case .direct: "Connexion directe"
        case .cloud: "Connexion iCloud (asynchrone)"
        }
    }

    var detail: String {
        switch self {
        case .direct: "L’iPhone joint directement `hermes serve`. Temps réel, voix, pièces jointes."
        case .cloud: "Passe par l’app NeoOS sur le Mac. Texte seulement, réponse quand le Mac a terminé."
        }
    }
}

/// Where the choice lives. Kept out of `AppModel` so switching modes never rewrites a connection.
enum ConnectionModeStore {
    private static let key = "connectionMode"

    static func load(_ defaults: UserDefaults = .standard) -> ConnectionMode {
        guard let raw = defaults.string(forKey: key), let mode = ConnectionMode(rawValue: raw) else {
            // No field, or a value written by a newer build: keep the existing behaviour.
            return .direct
        }
        return mode
    }

    static func save(_ mode: ConnectionMode, _ defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key)
    }
}
