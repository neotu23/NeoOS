import SwiftUI
import Observation

/// « Messagerie » — the desktop Messaging page (apps/desktop/src/app/messaging). Platforms:
/// `/api/messaging/platforms` (hermes_cli/web_routers/messaging.py), pairing: `/api/pairing`
/// (ops.py), gateway lifecycle: `/api/gateway/{start,restart}` (ops.py, actions.py).
struct MessagingSettingsView: View {
    let app: AppModel
    @State private var scope: String
    @State private var store: AccountsMessagingStore
    @State private var search = ""
    @State private var restarting = false

    init(app: AppModel, profile: String? = nil) {
        self.app = app
        let name = profile ?? app.profile
        _scope = State(initialValue: name)
        _store = State(initialValue: AccountsMessagingStore(tools: NativeToolSession(app, profile: name)))
    }

    private var profileTitle: String { app.profiles.first { $0.name == scope }?.title ?? scope }
    private var filtered: [JSONValue] {
        store.platforms.filter { search.isEmpty || "\($0["name"].string) \($0["description"].string)".localizedCaseInsensitiveContains(search) }
    }
    private var active: [JSONValue] { filtered.filter { $0["enabled"].bool || $0["configured"].bool } }
    private var available: [JSONValue] { filtered.filter { !$0["enabled"].bool && !$0["configured"].bool } }

    var body: some View {
        List {
            AppSearchSection(text: $search, prompt: L("Rechercher dans la messagerie…"))
            if app.demo { AccountsDemoNotice() }
            AccountsScopeSection(app: app, profile: $scope,
                note: "Jetons, listes d’accès et canaux de « \(profileTitle) ». Ils vivent dans le .env et le config.yaml de ce profil sur le serveur ; deux agents ne peuvent pas partager le même bot.")
            ToolFeedback(tools: store.tools)
            if store.loaded { gatewaySection }
            if !store.loaded && store.loading {
                SkeletonRows(count: 4)
            }
            if !active.isEmpty { Section(L("Vos canaux")) { ForEach(active, id: \.["id"].string) { link($0) } } }
            if !available.isEmpty { Section(L("Disponibles")) { ForEach(available, id: \.["id"].string) { link($0) } } }
        }.modernList().navigationTitle(L("Messagerie")).navigationBarTitleDisplayMode(.inline)
            .task(id: scope) {
                if store.tools.profile != scope { store = AccountsMessagingStore(tools: NativeToolSession(app, profile: scope)) }
                await store.load()
            }
            .refreshable { await store.load() }
            .appConfirm(L("Redémarrer le gateway de messagerie ?"), isPresented: $restarting) {
                Button(store.gatewayRunning ? L("Redémarrer maintenant") : L("Démarrer")) { Task { await store.restartGateway() } }
            } message: { Text(L("Les canaux de « %@ » se reconnectent avec les nouveaux paramètres. Les conversations en cours sur Telegram, Discord… peuvent être brièvement interrompues.", profileTitle)) }
    }

    @ViewBuilder private var gatewaySection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(AppTheme.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Gateway de messagerie")).font(.subheadline.weight(.medium))
                    AccountsStatusLabel(set: store.gatewayRunning, text: store.gatewayRunning ? L("En marche") : L("Gateway de messagerie arrêté"))
                }
                Spacer(minLength: 8)
                Button(store.gatewayRunning ? L("Redémarrer") : L("Démarrer")) { restarting = true }
                    .font(.caption.weight(.semibold)).buttonStyle(.borderless).disabled(store.tools.busy || app.demo)
            }.padding(.vertical, 4)
            if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        } footer: {
            if store.restartNeeded { Text(L("Enregistré. Redémarrez le gateway de messagerie pour appliquer les nouveaux paramètres.")).foregroundStyle(AppTheme.accent) }
        }
    }

    private func link(_ platform: JSONValue) -> some View {
        let id = platform["id"].string
        let pending = store.pending(for: id).count
        return NavigationLink { AccountsPlatformView(store: store, platformID: id, profileTitle: profileTitle) } label: {
            HStack(spacing: 12) {
                Image(systemName: Self.symbol(id)).font(.system(size: 17)).foregroundStyle(AppTheme.color(id)).frame(width: 30, height: 30)
                    .background(AppTheme.color(id).opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(platform["name"].string).font(.subheadline.weight(.medium))
                    AccountsStatusLabel(set: platform["state"].string == "connected", text: Self.state(platform["state"].string))
                }
                Spacer(minLength: 0)
                if pending > 0 {
                    Text("\(pending)").font(.caption2.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(AppTheme.accent, in: Capsule()).accessibilityLabel("\(pending) demandes d’appairage en attente")
                }
            }.padding(.vertical, 3)
        }.accessibilityIdentifier("messaging-" + id)
    }

    static func state(_ value: String) -> String {
        ["connected": L("Connecté"), "connecting": L("Connexion"), "disabled": L("Désactivé"), "fatal": L("Erreur"),
         "gateway_stopped": L("Gateway de messagerie arrêté"), "not_configured": L("Nécessite une configuration"),
         "pending_restart": L("Redémarrage requis"), "retrying": L("Nouvelle tentative"), "startup_failed": L("Échec du démarrage")][value] ?? (value.isEmpty ? L("Inconnu") : value)
    }

    static func symbol(_ id: String) -> String {
        ["telegram": "paperplane", "discord": "gamecontroller", "slack": "number", "signal": "lock.shield", "whatsapp": "phone.bubble",
         "matrix": "square.grid.3x3", "email": "envelope", "sms": "message", "webhook": "arrow.triangle.branch", "api_server": "server.rack",
         "mattermost": "bubble.left.and.bubble.right", "imessage": "message.fill", "teams": "person.3"][id] ?? "bubble.left"
    }
}

@MainActor @Observable
final class AccountsMessagingStore {
    let tools: NativeToolSession
    var platforms: [JSONValue] = []
    var pairing: JSONValue = [:]
    var loaded = false
    var loading = false
    var restartNeeded = false
    var notice: String?
    var gatewayRunning: Bool { platforms.contains { $0["gateway_running"].bool } }

    init(tools: NativeToolSession) { self.tools = tools }

    func platform(_ id: String) -> JSONValue? { platforms.first { $0["id"].string == id } }
    func pending(for id: String) -> [JSONValue] { pairing["pending"].array.filter { $0["platform"].string == id } }
    func approved(for id: String) -> [JSONValue] { pairing["approved"].array.filter { $0["platform"].string == id } }

    func load() async {
        if tools.app.demo { platforms = Self.demo; loaded = true; return }
        loading = true
        defer { loading = false }
        do {
            platforms = try await tools.request("/api/messaging/platforms")["platforms"].array
            loaded = true
            pairing = (try? await tools.request("/api/pairing")) ?? [:]
        } catch is CancellationError {
        } catch { tools.error = error.localizedDescription }
    }

    /// PUT /api/messaging/platforms/{id} — `enabled`, `env` (non-empty values) and `clear_env`.
    @discardableResult func update(_ id: String, enabled: Bool? = nil, env: [String: String] = [:], clear: [String] = []) async -> Bool {
        var done = false
        await tools.perform {
            var body: [String: JSONValue] = ["env": .object(env.mapValues(JSONValue.string)), "clear_env": .array(clear.map(JSONValue.string))]
            if let enabled { body["enabled"] = .bool(enabled) }
            let result = try await tools.request("/api/messaging/platforms/" + Accounts.segment(id), method: "PUT", body: .object(body))
            if result["hot_served"].bool { notice = L("Appliqué au gateway en cours d’exécution.") }
            else if gatewayRunning { restartNeeded = true }
            done = true
        }
        if done { await load() }
        return done
    }

    func restartGateway() async {
        await tools.perform {
            _ = try await tools.request(gatewayRunning ? "/api/gateway/restart" : "/api/gateway/start", method: "POST")
            restartNeeded = false
            notice = gatewayRunning ? L("Redémarrage du gateway en cours…") : L("Démarrage du gateway en cours…")
        }
        try? await Task.sleep(for: .seconds(4))
        await load()
    }

    func approve(_ request: JSONValue) async {
        await tools.perform {
            _ = try await tools.request("/api/pairing/approve", method: "POST",
                body: ["platform": .string(request["platform"].string), "request_id": .string(request["request_id"].string)])
        }
        await load()
    }

    func revoke(_ user: JSONValue) async {
        await tools.perform {
            _ = try await tools.request("/api/pairing/revoke", method: "POST",
                body: ["platform": .string(user["platform"].string), "user_id": .string(user["user_id"].string)])
        }
        await load()
    }

    private static let demo: [JSONValue] = [
        ["id": "telegram", "name": .string(L("Telegram")), "description": .string(L("Discutez avec votre agent depuis Telegram.")), "enabled": true, "configured": true,
         "gateway_running": true, "state": "connected", "env_vars": [["key": "TELEGRAM_BOT_TOKEN", "required": true, "is_set": true, "is_password": true, "prompt": .string(L("Jeton du bot")), "redacted_value": .string(L("«redacted:123…wxyz»"))]]],
        ["id": "discord", "name": .string(L("Discord")), "description": .string(L("Un bot Discord pour vos serveurs.")), "enabled": false, "configured": false, "state": "disabled",
         "env_vars": [["key": "DISCORD_BOT_TOKEN", "required": true, "is_set": false, "is_password": true, "prompt": .string(L("Jeton du bot"))]]],
        ["id": "slack", "name": .string(L("Slack")), "description": .string(L("Votre agent dans Slack.")), "enabled": false, "configured": false, "state": "disabled", "env_vars": []]
    ]
}

/// One platform: enable, credentials, allowlists, test, pairing — like a desktop Messaging card.
private struct AccountsPlatformView: View {
    let store: AccountsMessagingStore
    let platformID: String
    let profileTitle: String
    @State private var drafts: [String: String] = [:]
    @State private var showAdvanced = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var telegramSetup = false
    @State private var clearing: String?
    private var platform: JSONValue { store.platform(platformID) ?? [:] }
    private var fields: [JSONValue] { platform["env_vars"].array }
    private var name: String { platform["name"].string }

    private var changes: [String: String] {
        var result: [String: String] = [:]
        for field in fields {
            let key = field["key"].string
            guard let draft = drafts[key]?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
            if field["is_list"].bool { if draft != field["value"].string, !draft.isEmpty { result[key] = draft } }
            else if !draft.isEmpty { result[key] = draft }
        }
        return result
    }
    private var clearedLists: [String] {
        fields.filter { $0["is_list"].bool && $0["is_set"].bool && drafts[$0["key"].string]?.trimmingCharacters(in: .whitespaces) == "" }.map { $0["key"].string }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: MessagingSettingsView.symbol(platformID)).font(.system(size: 20)).foregroundStyle(AppTheme.color(platformID))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.headline)
                            AccountsStatusLabel(set: platform["state"].string == "connected", text: MessagingSettingsView.state(platform["state"].string))
                        }
                    }
                    if !platform["description"].string.isEmpty { Text(platform["description"].string).font(.caption).foregroundStyle(.secondary) }
                    if !platform["error_message"].string.isEmpty { Text(platform["error_message"].string).font(.caption).foregroundStyle(AppTheme.accent) }
                    if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
                Toggle(L("Activé"), isOn: Binding(get: { platform["enabled"].bool }, set: { value in
                    Task { await store.update(platformID, enabled: value) }
                })).disabled(store.tools.busy || store.tools.app.demo)
                if let docs = URL(string: platform["docs_url"].string), docs.scheme == "https" {
                    Link(destination: docs) { Label(L("Ouvrir le guide de configuration"), systemImage: "book") }
                }
            } footer: {
                if !platform["ingress_url"].string.isEmpty { Text(L("Servi sur le listener partagé du gateway à %@", platform["ingress_url"].string)) }
            }
            if platformID == "telegram" {
                Section {
                    Button { telegramSetup = true } label: { Label(L("Créer un bot avec Telegram"), systemImage: "paperplane") }
                        .disabled(store.tools.app.demo)
                } footer: { Text(L("Ouvre Telegram sur cet iPhone pour créer le bot, puis Hermes enregistre son jeton et vous autorise automatiquement.")) }
            }
            ToolFeedback(tools: store.tools)
            let basic = fields.filter { !$0["advanced"].bool }, advanced = fields.filter { $0["advanced"].bool }
            if fields.isEmpty {
                Section { Text(L("Cette plateforme ne nécessite pas de jeton ici. Utilisez le guide de configuration ci-dessus, puis activez-la.")).font(.subheadline).foregroundStyle(.secondary) }
            }
            if !basic.isEmpty { Section(L("Identifiants")) { ForEach(basic, id: \.["key"].string) { fieldRow($0) } } }
            if !advanced.isEmpty {
                Section {
                    DisclosureGroup("Avancé (\(advanced.count))", isExpanded: $showAdvanced) { ForEach(advanced, id: \.["key"].string) { fieldRow($0) } }
                }
            }
            if !fields.isEmpty {
                Section {
                    Button(L("Enregistrer les modifications")) {
                        let env = changes, clear = clearedLists
                        Task { if await store.update(platformID, env: env, clear: clear) { drafts = [:] } }
                    }.disabled((changes.isEmpty && clearedLists.isEmpty) || store.tools.busy || store.tools.app.demo)
                } footer: { Text(L("Les valeurs secrètes sont envoyées au serveur de « %@ » puis effacées de ce formulaire.", profileTitle)) }
            }
            Section {
                Button { Task { await test() } } label: { Label(L("Tester la connexion"), systemImage: "checkmark.seal") }
                    .disabled(store.tools.busy || store.tools.app.demo)
                if let testResult { Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle" : "exclamationmark.triangle").font(.subheadline).foregroundStyle(testResult.ok ? .green : .orange) }
            }
            pairingSections
        }.modernList().navigationTitle(name).navigationBarTitleDisplayMode(.inline)
            .onDisappear { drafts = [:] }
            .sheet(isPresented: $telegramSetup) { AccountsTelegramSetup(store: store) }
            .appConfirm(L("Effacer %@ ?", clearing ?? ""), isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } })) {
                Button(L("Effacer"), role: .destructive) {
                    guard let key = clearing else { return }; clearing = nil
                    Task { await store.update(platformID, clear: [key]) }
                }
            }
    }

    private var hint: String? {
        switch platform["state"].string {
        case "pending_restart": L("Redémarrez le gateway (écran précédent) pour appliquer ce changement.")
        case "gateway_stopped": L("Démarrez le gateway (écran précédent) pour vous connecter.")
        default: nil
        }
    }

    @ViewBuilder private func fieldRow(_ field: JSONValue) -> some View {
        let key = field["key"].string
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(field["prompt"].string.isEmpty ? key : field["prompt"].string).font(.subheadline.weight(.medium))
                if field["required"].bool { Text(L("Requis")).font(.caption2.weight(.semibold)).foregroundStyle(AppTheme.accent) }
            }
            Text(key).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            if field["is_list"].bool {
                TextField(L("Identifiants séparés par des virgules"), text: Binding(get: { drafts[key] ?? field["value"].string }, set: { drafts[key] = $0 }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout.monospaced())
            } else if field["is_password"].bool {
                SecureField(field["is_set"].bool ? L("Remplacer la valeur actuelle") : L("Coller la valeur"), text: Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } else {
                TextField(field["is_set"].bool ? L("Remplacer la valeur actuelle") : L("Valeur"), text: Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            HStack {
                if !field["is_list"].bool {
                    AccountsStatusLabel(set: field["is_set"].bool, text: field["is_set"].bool ? L("Identifiants définis %@", Accounts.maskedHint(field["redacted_value"].string)) : L("Non défini"))
                }
                Spacer(minLength: 0)
                if field["is_set"].bool && !field["is_list"].bool {
                    Button(L("Effacer"), role: .destructive) { clearing = key }.font(.caption).buttonStyle(.borderless)
                }
            }
            if !field["help"].string.isEmpty || !field["description"].string.isEmpty {
                Text(field["help"].string.isEmpty ? field["description"].string : field["help"].string).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }

    @ViewBuilder private var pairingSections: some View {
        let pending = store.pending(for: platformID), approved = store.approved(for: platformID)
        if !pending.isEmpty {
            Section(L("Demandes en attente (%lld)", pending.count)) {
                ForEach(Array(pending.enumerated()), id: \.offset) { _, request in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(request["user_name"].string.isEmpty ? request["user_id"].string : request["user_name"].string).font(.subheadline)
                            Text(request["age_minutes"].int < 1 ? L("à l’instant") : L("il y a %lld min", request["age_minutes"].int)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Approuver")) { Task { await store.approve(request) } }.buttonStyle(.borderless)
                            .disabled(store.tools.busy || request["request_id"].string.isEmpty)
                    }
                }
            }
        }
        if !approved.isEmpty {
            Section(L("Utilisateurs approuvés (%lld)", approved.count)) {
                ForEach(Array(approved.enumerated()), id: \.offset) { _, user in
                    HStack {
                        Text(user["user_name"].string.isEmpty ? user["user_id"].string : user["user_name"].string).font(.subheadline)
                        Spacer()
                        Button(L("Révoquer"), role: .destructive) { Task { await store.revoke(user) } }.buttonStyle(.borderless).disabled(store.tools.busy)
                    }
                }
            }
        }
    }

    private func test() async {
        testResult = nil
        do {
            let result = try await store.tools.request("/api/messaging/platforms/" + Accounts.segment(platformID) + "/test", method: "POST")
            testResult = (true, result["message"].string.isEmpty ? L("Connecté.") : result["message"].string)
        } catch { testResult = (false, error.localizedDescription) }
    }
}

/// Telegram QR/deep-link onboarding (messaging.py `/api/messaging/telegram/onboarding/*`).
private struct AccountsTelegramSetup: View {
    let store: AccountsMessagingStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var botName = L("Hermes Agent")
    @State private var pairing: JSONValue = .null
    @State private var ready: JSONValue = .null
    @State private var status = "idle"
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                if status == "idle" || status == "error" {
                    Section {
                        TextField(L("Nom du bot"), text: $botName)
                    } footer: { Text(L("Telegram s’ouvre pour créer le bot. Revenez ensuite ici : Hermes récupère son jeton automatiquement.")) }
                    Button(L("Ouvrir Telegram")) { Task { await start() } }.disabled(botName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if status == "waiting" {
                    Section {
                        HStack { ProgressView(); Text(L("En attente de Telegram…")).foregroundStyle(.secondary) }
                        if let link = URL(string: pairing["deep_link"].string) { Button { openURL(link) } label: { Label(L("Rouvrir Telegram"), systemImage: "paperplane") } }
                    } footer: { Text(L("Suivez les étapes dans Telegram pour créer %@.", pairing["suggested_username"].string.isEmpty ? L("le bot") : "@" + pairing["suggested_username"].string)) }
                }
                if status == "ready" {
                    Section {
                        Label(L("Bot %@ prêt", ready["bot_username"].string.isEmpty ? "" : "@" + ready["bot_username"].string), systemImage: "checkmark.circle").foregroundStyle(.green)
                        Button(L("Enregistrer et m’autoriser")) { Task { await apply() } }.disabled(store.tools.busy)
                    } footer: { Text(L("Seul votre compte Telegram (ID %@) pourra parler à ce bot. Le gateway redémarre ensuite.", ready["owner_user_id"].displayText)) }
                }
                if status == "done" { Section { Label(message ?? L("Telegram est configuré."), systemImage: "checkmark.circle.fill").foregroundStyle(.green) } }
                if let message, status == "error" { Section { Text(message).foregroundStyle(AppTheme.accent) } }
                ToolFeedback(tools: store.tools)
            }.modernList().navigationTitle(L("Configurer Telegram")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    AppToolbarItem(placement: .cancellationAction) {
                        Button(status == "done" ? L("Terminé") : L("Annuler")) { Task { await cancel(); dismiss() } }
                    }
                }
                .task(id: pairing["pairing_id"].string) { await poll() }
        }.presentationBackground(AppTheme.background)
    }

    private var pairingPath: String { "/api/messaging/telegram/onboarding/" + Accounts.segment(pairing["pairing_id"].string) }

    private func start() async {
        message = nil
        do {
            pairing = try await store.tools.request("/api/messaging/telegram/onboarding/start", method: "POST", body: ["bot_name": .string(botName)])
            status = "waiting"
            if let link = URL(string: pairing["deep_link"].string) { openURL(link) }
        } catch { status = "error"; message = error.localizedDescription }
    }

    private func poll() async {
        guard !pairing["pairing_id"].string.isEmpty else { return }
        while status == "waiting" {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            do {
                let result = try await store.tools.request(pairingPath)
                if result["status"].string == "ready" { ready = result; status = "ready" }
            } catch is CancellationError { return }
            catch { status = "error"; message = error.localizedDescription }
        }
    }

    private func apply() async {
        await store.tools.perform {
            let result = try await store.tools.request(pairingPath + "/apply", method: "POST",
                body: ["allowed_user_ids": [.string(ready["owner_user_id"].displayText)]])
            status = "done"
            message = result["needs_restart"].bool ? L("Enregistré. Redémarrez le gateway de messagerie pour connecter le bot.") : L("Telegram est configuré et le gateway redémarre.")
        }
        await store.load()
    }

    private func cancel() async {
        guard ["waiting", "ready"].contains(status), !pairing["pairing_id"].string.isEmpty else { return }
        _ = try? await store.tools.request(pairingPath, method: "DELETE")
    }
}
