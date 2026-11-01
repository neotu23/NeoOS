import SwiftUI

/// « Fournisseurs » — desktop providers-settings.tsx + custom-endpoints-settings.tsx.
/// Accounts: `/api/providers/oauth` (hermes_cli/web_routers/oauth.py); API keys: `/api/env`
/// (category `provider`); endpoints: `/api/providers/custom-endpoints` (config_env.py).
struct ProvidersSettingsView: View {
    let app: AppModel
    @State private var scope: String
    @State private var store: AccountsEnvStore
    @State private var oauth: [JSONValue] = []
    @State private var oauthLoaded = false
    @State private var endpoints: [JSONValue] = []
    @State private var current: JSONValue = [:]
    @State private var search = ""
    @State private var signingIn: JSONValue?
    @State private var disconnecting: JSONValue?
    @State private var editing: JSONValue?
    @State private var creating = false
    @State private var deleting: JSONValue?
    @State private var notice: String?

    init(app: AppModel, profile: String? = nil) {
        self.app = app
        let name = profile ?? app.profile
        _scope = State(initialValue: name)
        _store = State(initialValue: AccountsEnvStore(tools: NativeToolSession(app, profile: name)))
    }

    private var tools: NativeToolSession { store.tools }
    private var profileTitle: String { app.profiles.first { $0.name == scope }?.title ?? scope }

    /// Same grouping as the desktop `buildProviderKeyGroups`: by catalog provider label.
    private var groups: [(name: String, keys: [AccountsCredential])] {
        let rows = store.rows.values.filter { $0.category == "provider" }
        let grouped = Dictionary(grouping: rows) { row -> String in
            let label = row.providerLabel.trimmingCharacters(in: .whitespaces)
            if !label.isEmpty { return label }
            if !row.provider.isEmpty { return row.provider }
            return row.key.components(separatedBy: "_").first?.capitalized ?? row.key
        }
        return grouped.map { name, keys in
            (name: name, keys: keys.sorted { ($0.providerPrimary ? 0 : 1, $0.key) < ($1.providerPrimary ? 0 : 1, $1.key) })
        }.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.keys.contains { $0.key.localizedCaseInsensitiveContains(search) } }
            .sorted { ($0.keys.contains(where: \.isSet) ? 0 : 1, $0.name.lowercased()) < ($1.keys.contains(where: \.isSet) ? 0 : 1, $1.name.lowercased()) }
    }

    var body: some View {
        List {
            AppSearchSection(text: $search, prompt: L("Rechercher des fournisseurs…"))
            if app.demo { AccountsDemoNotice() }
            AccountsScopeSection(app: app, profile: $scope,
                note: "Comptes, clés et points de terminaison de « \(profileTitle) ». Les clés vont dans le .env de ce profil sur le serveur ; les points de terminaison dans son config.yaml.")
            ToolFeedback(tools: tools)
            if let notice { Section { Label(notice, systemImage: "checkmark.circle").foregroundStyle(.green) } }
            if search.isEmpty { accountsSection }
            keysSection
            if search.isEmpty { endpointsSection }
        }.modernList().navigationTitle(L("Fournisseurs")).navigationBarTitleDisplayMode(.inline)
            .task(id: scope) { await reload() }
            .refreshable { await reload() }
            .sheet(item: Binding(get: { signingIn.map(AccountsIdentified.init) }, set: { signingIn = $0?.value })) { item in
                AccountsDeviceLogin(tools: tools, provider: item.value) { Task { await loadOAuth() } }
            }
            .sheet(isPresented: $creating) { AccountsEndpointForm(tools: tools, endpoint: nil) { response in apply(response) } }
            .sheet(item: Binding(get: { editing.map(AccountsIdentified.init) }, set: { editing = $0?.value })) { item in
                AccountsEndpointForm(tools: tools, endpoint: item.value) { response in apply(response) }
            }
            .appConfirm(L("Déconnecter %@ ?", disconnecting?["name"].string ?? ""), isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } })) {
                Button(L("Déconnecter"), role: .destructive) {
                    guard let provider = disconnecting else { return }; disconnecting = nil
                    Task { await tools.perform {
                        _ = try await tools.request("/api/providers/oauth/" + Accounts.segment(provider["id"].string), method: "DELETE")
                        notice = L("%@ a été supprimé.", provider["name"].string)
                        await loadOAuth()
                    } }
                }
            } message: { Text(L("Les identifiants enregistrés par Hermes pour ce compte seront retirés de « %@ ».", profileTitle)) }
            .appConfirm(L("Supprimer %@ ?", deleting?["name"].string ?? ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(L("Supprimer le point de terminaison"), role: .destructive) {
                    guard let endpoint = deleting else { return }; deleting = nil
                    Task { await tools.perform {
                        apply(try await tools.request("/api/providers/custom-endpoints/" + Accounts.segment(endpoint["id"].string), method: "DELETE"))
                    } }
                }
            } message: { Text(L("Sa clé API éventuelle est aussi retirée du .env de ce profil.")) }
    }

    // MARK: Accounts (OAuth)

    @ViewBuilder private var accountsSection: some View {
        Section {
            if !oauthLoaded && !app.demo {
                SkeletonRows(count: 3)
            } else if oauth.isEmpty {
                Text(app.demo ? L("Nous Portal, ChatGPT/Codex, xAI…") : L("Aucun fournisseur compatible OAuth détecté.")).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(oauth, id: \.["id"].string) { provider in oauthRow(provider) }
        } header: { Text(L("Connecter un compte")) } footer: {
            Text(L("Connectez-vous avec un abonnement, sans clé API à copier. Les connexions par code d’appareil se font depuis cet iPhone ; celles gérées par une CLI externe se lancent sur le serveur (desktop ou terminal)."))
        }
    }

    private func oauthRow(_ provider: JSONValue) -> some View {
        let status = provider["status"]
        let connected = status["logged_in"].bool
        let flow = provider["flow"].string
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider["name"].string).font(.subheadline.weight(.medium))
                    AccountsStatusLabel(set: connected, text: oauthStatus(status))
                }
                Spacer(minLength: 8)
                if connected {
                    if provider["disconnectable"].bool {
                        Button(L("Déconnecter")) { disconnecting = provider }.font(.caption).buttonStyle(.borderless).disabled(tools.busy || app.demo)
                    }
                } else if flow == "device_code" {
                    Button(L("Connexion")) { notice = nil; signingIn = provider }.font(.caption.weight(.semibold)).buttonStyle(.borderless)
                        .disabled(app.demo)
                }
            }
            if !connected && flow != "device_code" && !provider["cli_command"].string.isEmpty {
                Text(L("Géré en externe : exécutez sur le serveur")).font(.caption).foregroundStyle(.secondary)
                AccountsCommandRow(command: provider["cli_command"].string)
            } else if connected, !provider["disconnect_hint"].string.isEmpty, !provider["disconnectable"].bool {
                Text(status["source"].string == "env_var" ? L("Configuré depuis une clé API : supprimez-la dans les clés ci-dessous.") : L("Géré par sa propre CLI : déconnectez-le sur le serveur."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }

    private func oauthStatus(_ status: JSONValue) -> String {
        guard status["logged_in"].bool else { return status["error"].string.isEmpty ? L("Non connecté") : L("Erreur : %@", status["error"].string) }
        var parts = [L("Connecté")]
        if !status["source_label"].string.isEmpty { parts.append(status["source_label"].string) }
        if !status["token_preview"].string.isEmpty { parts.append("…" + status["token_preview"].string.suffix(4)) }
        return parts.joined(separator: " · ")
    }

    // MARK: API keys

    @ViewBuilder private var keysSection: some View {
        Section {
            if !store.loaded && store.loading { SkeletonRows(count: 4) }
            else if groups.isEmpty { Text(search.isEmpty ? L("Aucune clé API de fournisseur disponible.") : L("Aucun fournisseur ne correspond à votre recherche.")).font(.subheadline).foregroundStyle(.secondary) }
            ForEach(groups, id: \.name) { group in
                if group.keys.count == 1, let only = group.keys.first {
                    NavigationLink { AccountsCredentialEditor(store: store, key: only.key, profileTitle: profileTitle, providerSetup: true) } label: { groupLabel(group.name, group.keys) }
                } else {
                    NavigationLink {
                        List {
                            ToolFeedback(tools: tools)
                            ForEach(group.keys) { key in
                                NavigationLink { AccountsCredentialEditor(store: store, key: key.key, profileTitle: profileTitle, providerSetup: true) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(Accounts.suffix(key.key).capitalized(with: Locale(identifier: "fr"))).font(.subheadline.weight(.medium))
                                        Text(key.key).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                        AccountsStatusLabel(set: key.isSet, text: key.status)
                                    }.padding(.vertical, 3)
                                }
                            }
                        }.modernList().navigationTitle(group.name).navigationBarTitleDisplayMode(.inline)
                    } label: { groupLabel(group.name, group.keys) }
                }
            }
        } header: {
            Text(L("Vous avez une clé API ?"))
        } footer: {
            let total = groups.count, configured = groups.filter { $0.keys.contains(where: \.isSet) }.count
            if search.isEmpty && total > 0 { Text(L("%lld sur %lld fournisseurs configurés.", configured, total)) }
        }
    }

    private func groupLabel(_ name: String, _ keys: [AccountsCredential]) -> some View {
        let set = keys.filter(\.isSet)
        return VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.subheadline.weight(.medium))
            AccountsStatusLabel(set: !set.isEmpty, text: set.isEmpty ? "Non défini" : (set.first?.status ?? L("Configurée")))
        }.padding(.vertical, 3)
    }

    // MARK: Custom endpoints

    @ViewBuilder private var endpointsSection: some View {
        Section {
            if endpoints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Aucun point de terminaison personnalisé")).font(.subheadline.weight(.medium))
                    Text(L("Pointez Hermes vers n’importe quel point de terminaison compatible OpenAI (vLLM, llama.cpp, Ollama…).")).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 3)
            }
            ForEach(endpoints, id: \.["id"].string) { endpoint in
                Button { editing = endpoint } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(endpoint["name"].string).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                if endpoint["is_current"].bool {
                                    Text(L("Actif")).font(.caption2.weight(.semibold)).foregroundStyle(AppTheme.accent)
                                        .padding(.horizontal, 6).padding(.vertical, 2).background(AppTheme.accent.opacity(0.1), in: Capsule())
                                }
                            }
                            Text(endpoint["base_url"].string).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            Text([endpoint["model"].string, endpoint["has_api_key"].bool ? L("Clé API définie") : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }.padding(.vertical, 3).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .swipeActions {
                        Button(L("Supprimer"), role: .destructive) { deleting = endpoint }
                        if !endpoint["is_current"].bool { Button(L("Utiliser")) { activate(endpoint) }.tint(AppTheme.accent) }
                    }
            }
            Button { creating = true } label: { Label(L("Nouveau point de terminaison"), systemImage: "plus") }.disabled(app.demo)
        } header: { Text(L("Points de terminaison personnalisés")) } footer: {
            if !current["provider"].string.isEmpty {
                Text(L("Modèle actuel de cet agent : %@ · %@", current["model"].string, current["provider"].string))
            }
        }
    }

    private func activate(_ endpoint: JSONValue) {
        Task { await tools.perform {
            let result = try await tools.request("/api/providers/custom-endpoints/" + Accounts.segment(endpoint["id"].string) + "/activate", method: "POST")
            notice = L("%@ est maintenant utilisé (%@).", endpoint["name"].string, result["model"].string)
            await loadEndpoints()
        } }
    }

    private func apply(_ response: JSONValue) {
        if case .array = response["endpoints"] { endpoints = response["endpoints"].array; current = response["current"] }
    }

    // MARK: Loading

    private func reload() async {
        if tools.profile != scope {
            store = AccountsEnvStore(tools: NativeToolSession(app, profile: scope))
            oauth = []; oauthLoaded = false; endpoints = []; current = [:]; notice = nil
        }
        await store.load()
        await loadOAuth()
        await loadEndpoints()
    }

    private func loadOAuth() async {
        if app.demo {
            oauth = [["id": "nous", "name": .string(L("Nous Portal")), "flow": "device_code", "status": ["logged_in": true, "source_label": .string(L("Abonnement"))], "disconnectable": true],
                     ["id": "openai-codex", "name": .string(L("ChatGPT or Codex Subscription")), "flow": "device_code", "status": ["logged_in": false]],
                     ["id": "anthropic", "name": .string(L("Anthropic Account")), "flow": "external", "cli_command": "hermes auth add anthropic", "status": ["logged_in": false]]]
            return
        }
        do { oauth = try await tools.request("/api/providers/oauth")["providers"].array; oauthLoaded = true }
        catch is CancellationError { }
        catch { oauthLoaded = true; tools.error = error.localizedDescription }
    }

    private func loadEndpoints() async {
        if app.demo { return }
        do { apply(try await tools.request("/api/providers/custom-endpoints")) }
        catch is CancellationError { }
        catch { tools.error = error.localizedDescription }
    }
}

/// Device-code sign-in: start → show the code → open the provider page → poll until approved.
private struct AccountsDeviceLogin: View {
    let tools: NativeToolSession
    let provider: JSONValue
    var finished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var session: JSONValue = .null
    @State private var status = "starting"
    @State private var message: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(provider["name"].string).font(.headline)
                    switch status {
                    case "starting": HStack { ProgressView(); Text(L("Lancement du flux de connexion…")).foregroundStyle(.secondary) }
                    case "pending": HStack { ProgressView(); Text(L("En attente de votre autorisation dans le navigateur…")).foregroundStyle(.secondary) }
                    case "approved": Label(L("Connecté !"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    default: Label(message ?? L("Échec de la connexion."), systemImage: "exclamationmark.circle").foregroundStyle(AppTheme.accent)
                    }
                }
                if !session["user_code"].string.isEmpty && status != "approved" {
                    Section {
                        HStack {
                            Text(session["user_code"].string).font(.system(.title2, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                            Spacer()
                            Button { UIPasteboard.general.string = session["user_code"].string; copied = true } label: {
                                Label(copied ? L("Copié") : L("Copier le code"), systemImage: copied ? "checkmark" : "doc.on.doc")
                            }.buttonStyle(.borderless)
                        }
                        if let url = URL(string: session["verification_url"].string) {
                            Button { openURL(url) } label: { Label(L("Ouvrir la page de vérification"), systemImage: "safari") }
                        }
                    } header: { Text(L("Saisissez ce code si demandé")) } footer: {
                        Text(L("Connectez-vous dans Safari puis revenez ici : Hermes enregistre le compte sur le serveur dès que vous avez autorisé l’accès."))
                    }
                }
                if status == "error" || status == "expired" {
                    Button(L("Réessayer")) { Task { await start() } }
                }
            }.modernList().navigationTitle(L("Connecter un compte")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    AppToolbarItem(placement: .cancellationAction) {
                        Button(status == "approved" ? L("Terminé") : L("Annuler")) { Task { await cancel(); dismiss() } }
                    }
                }
                .task { await start() }
                .task(id: session["session_id"].string) { await poll() }
        }.presentationBackground(AppTheme.background).interactiveDismissDisabled(status == "pending")
    }

    private var providerID: String { Accounts.segment(provider["id"].string) }

    private func start() async {
        status = "starting"; message = nil; copied = false
        do {
            session = try await tools.request("/api/providers/oauth/\(providerID)/start", method: "POST", body: [:])
            status = "pending"
            if let url = URL(string: session["verification_url"].string) { openURL(url) }
        } catch {
            status = "error"
            message = (error as? RPCFailure)?.code == 401
                ? L("Hermes refuse de lancer cette connexion depuis l’app. Connectez ce compte depuis le desktop ou la CLI.")
                : error.localizedDescription
        }
    }

    private func poll() async {
        let id = session["session_id"].string
        guard !id.isEmpty else { return }
        let interval = max(2, session["poll_interval"].int)
        while status == "pending" {
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            do {
                let result = try await tools.request("/api/providers/oauth/\(providerID)/poll/\(Accounts.segment(id))")
                let next = result["status"].string
                if next != "pending" {
                    status = next == "approved" ? "approved" : (next == "expired" ? "expired" : "error")
                    message = result["error_message"].string.isEmpty ? (next == "expired" ? L("Session expirée. Réessayez pour démarrer une nouvelle connexion.") : nil) : result["error_message"].string
                    if next == "approved" { finished() }
                }
            } catch is CancellationError { return }
            catch { status = "error"; message = error.localizedDescription }
        }
    }

    private func cancel() async {
        let id = session["session_id"].string
        guard status == "pending", !id.isEmpty else { return }
        status = "cancelled"
        _ = try? await tools.request("/api/providers/oauth/sessions/\(Accounts.segment(id))", method: "DELETE")
    }
}

/// Add or edit an OpenAI-compatible endpoint (desktop custom-endpoints-settings.tsx).
private struct AccountsEndpointForm: View {
    let tools: NativeToolSession
    let endpoint: JSONValue?
    var saved: (JSONValue) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var clearKey = false
    @State private var apiMode = ""
    @State private var context = ""
    @State private var discover = true
    @State private var makeDefault = false
    @State private var models: [String] = []
    @State private var details: JSONValue = .null
    @State private var probe: (ok: Bool, text: String)?

    private var hasKey: Bool { endpoint?["has_api_key"].bool == true }
    private var payload: [String: JSONValue] {
        var body: [String: JSONValue] = ["id": .string(endpoint?["id"].string ?? ""), "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "base_url": .string(baseURL.trimmingCharacters(in: .whitespaces)), "model": .string(model.trimmingCharacters(in: .whitespaces)),
            "api_mode": .string(apiMode), "discover_models": .bool(discover), "make_default": .bool(makeDefault)]
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { body["api_key"] = .string(key) } else if clearKey { body["api_key"] = "" }
        if let length = Int(context), length > 0 { body["context_length"] = .number(Double(length)) }
        if !models.isEmpty { body["models"] = .array(models.map(JSONValue.string)) }
        if case .array = details { body["model_details"] = details }
        return body
    }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !model.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: baseURL.trimmingCharacters(in: .whitespaces)).map { ["http", "https"].contains($0.scheme ?? "") && $0.host != nil } == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Nom (ex. Proxy Axet)"), text: $name)
                    TextField(L("URL du point de terminaison"), text: $baseURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if models.isEmpty {
                        TextField(L("Modèle par défaut"), text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        AppPicker(title: L("Modèle par défaut"), selection: $model,
                                  options: (models.contains(model) ? [] : [(value: model, label: model.isEmpty ? L("Choisir") : model)]) + models.map { (value: $0, label: $0) })
                    }
                }
                Section {
                    SecureField(hasKey ? L("Laissez vide pour conserver la clé actuelle") : L("Clé API (facultatif)"), text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if hasKey { Toggle(L("Retirer la clé enregistrée"), isOn: $clearKey).disabled(!apiKey.isEmpty) }
                } header: { Text(L("Clé API")) } footer: { Text(L("La clé est écrite dans le .env de l’agent sur le serveur et référencée par la configuration ; elle n’est jamais renvoyée à l’app.")) }
                Section {
                    AppPicker(title: L("Mode API"), selection: $apiMode, options: [
                        (value: "", label: L("Détection automatique")), (value: "chat_completions", label: L("Chat Completions")),
                        (value: "codex_responses", label: L("Responses (Codex)")), (value: "anthropic_messages", label: L("Messages Anthropic"))])
                    TextField(L("Contexte (auto)"), text: $context).keyboardType(.numberPad)
                    Toggle(L("Découvrir les modèles"), isOn: $discover)
                    Toggle(L("Utiliser pour les nouvelles conversations"), isOn: $makeDefault)
                }
                Section {
                    Button { Task { await test() } } label: { Label(L("Tester"), systemImage: "antenna.radiowaves.left.and.right") }
                        .disabled(baseURL.isEmpty || tools.busy)
                    if let probe { Label(probe.text, systemImage: probe.ok ? "checkmark.circle" : "exclamationmark.triangle").font(.subheadline).foregroundStyle(probe.ok ? .green : .orange) }
                }
                ToolFeedback(tools: tools)
            }.modernList().navigationTitle(endpoint == nil ? L("Ajouter un point de terminaison") : L("Modifier le point de terminaison")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    AppToolbarItem(placement: .cancellationAction) { Button(L("Annuler")) { apiKey = ""; dismiss() } }
                    AppToolbarItem(placement: .confirmationAction) {
                        Button(L("Enregistrer")) { Task { await save() } }.disabled(!valid || tools.busy || tools.app.demo)
                    }
                }
                .task {
                    guard let endpoint else { return }
                    name = endpoint["name"].string; baseURL = endpoint["base_url"].string; model = endpoint["model"].string
                    apiMode = endpoint["api_mode"].string; discover = endpoint["discover_models"].isNull ? true : endpoint["discover_models"].bool
                    context = endpoint["context_length"].int > 0 ? String(endpoint["context_length"].int) : ""
                    models = endpoint["models"].array.map(\.string).filter { !$0.isEmpty }
                }
        }.presentationBackground(AppTheme.background)
    }

    private func test() async {
        probe = nil
        do {
            let result = try await tools.request("/api/providers/custom-endpoints/validate", method: "POST", body: .object(payload))
            let found = result["models"].array.map(\.string).filter { !$0.isEmpty }
            if !found.isEmpty { models = found; details = result["model_details"]; if model.isEmpty { model = found[0] } }
            probe = (true, found.isEmpty ? L("Le point de terminaison est joignable.") : L("Joignable : %lld modèle(s) trouvé(s).", found.count))
        } catch {
            probe = (false, error.localizedDescription)
        }
    }

    private func save() async {
        await tools.perform {
            let response = try await tools.request("/api/providers/custom-endpoints", method: "POST", body: .object(payload))
            apiKey = ""
            saved(response); dismiss()
        }
    }
}
