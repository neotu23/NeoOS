import SwiftUI

/// « Clés et identifiants » — the desktop Keys page (tools, settings, custom keys) plus a voice
/// group that puts ElevenLabs first. Values live in the profile's .env on the server
/// (`GET/PUT/DELETE /api/env`, hermes_cli/web_routers/config_env.py).
struct CredentialsSettingsView: View {
    let app: AppModel
    @State private var scope: String
    @State private var store: AccountsEnvStore
    @State private var search = ""
    @State private var showAdvanced = false
    @State private var adding = false
    @State private var ttsProvider = ""
    @State private var sttProvider = ""
    @State private var voiceNotice: String?

    init(app: AppModel, profile: String? = nil) {
        self.app = app
        let name = profile ?? app.profile
        _scope = State(initialValue: name)
        _store = State(initialValue: AccountsEnvStore(tools: NativeToolSession(app, profile: name)))
    }

    private static let voiceKeys = ["ELEVENLABS_API_KEY", "VOICE_TOOLS_OPENAI_KEY", "OPENAI_API_KEY", "GROQ_API_KEY",
                                    "MISTRAL_API_KEY", "XAI_API_KEY", "DEEPINFRA_API_KEY", "MINIMAX_API_KEY", "PORCUPINE_ACCESS_KEY"]
    private var profileTitle: String { app.profiles.first { $0.name == scope }?.title ?? scope }
    private var visible: [AccountsCredential] {
        store.rows.values.filter { !$0.channelManaged && (showAdvanced || !$0.advanced || $0.isSet) }.sorted { $0.key < $1.key }
    }
    private func rows(_ categories: Set<String>) -> [AccountsCredential] {
        visible.filter { categories.contains($0.category) && !Self.voiceKeys.contains($0.key) }
    }
    private var voiceRows: [AccountsCredential] {
        Self.voiceKeys.dropFirst().compactMap { store.rows[$0] }
    }
    private var otherRows: [AccountsCredential] {
        visible.filter { !["provider", "tool", "setting", "messaging", "custom"].contains($0.category) && !Self.voiceKeys.contains($0.key) }
    }
    private var providerRows: [AccountsCredential] { store.rows.values.filter { $0.category == "provider" } }
    private var searchResults: [AccountsCredential] {
        store.rows.values.filter { !$0.channelManaged && "\($0.key) \($0.title) \($0.detail)".localizedCaseInsensitiveContains(search) }
            .sorted { $0.key < $1.key }
    }
    private var eleven: AccountsCredential? { store.rows["ELEVENLABS_API_KEY"] }

    var body: some View {
        List {
            AppSearchSection(text: $search, prompt: L("Rechercher une clé"))
            if app.demo { AccountsDemoNotice() }
            AccountsScopeSection(app: app, profile: $scope, note: Accounts.scopeNote(profileTitle))
            ToolFeedback(tools: store.tools)
            if !store.loaded && store.loading {
                SkeletonRows(count: 5, avatar: false)
            } else if !search.isEmpty {
                Section(L("Résultats")) {
                    if searchResults.isEmpty { ContentUnavailableView.search(text: search) }
                    ForEach(searchResults) { credentialLink($0) }
                }
            } else if store.loaded {
                voiceSection
                Section {
                    NavigationLink { ProvidersSettingsView(app: app, profile: scope) } label: {
                        row(symbol: "cpu", title: L("Fournisseurs de modèles"),
                            detail: "\(providerRows.filter(\.isSet).count) clé(s) configurée(s) · comptes, clés et points de terminaison")
                    }
                } header: { Text(L("Fournisseurs LLM")) }
                credentialSection(L("Outils et recherche"), rows(["tool"]), empty: L("Rien configuré dans cette catégorie pour le moment."))
                credentialSection(L("Réglages du serveur"), rows(["setting", "messaging"]), empty: nil)
                Section {
                    NavigationLink { MessagingSettingsView(app: app, profile: scope) } label: {
                        row(symbol: "bubble.left.and.text.bubble.right", title: L("Messagerie"),
                            detail: L("Les jetons de Telegram, Discord, Slack… se gèrent avec leur plateforme"))
                    }
                }
                Section {
                    ForEach(rows(["custom"])) { credentialLink($0) }
                    Button { adding = true } label: { Label(L("Ajouter une clé personnalisée"), systemImage: "plus") }
                        .disabled(app.demo)
                } header: { Text(L("Clés personnalisées")) } footer: {
                    Text(L("Variables d’environnement arbitraires que Hermes ne reconnaît pas. Utilisez-les pour des skills, des serveurs MCP ou vos propres outils."))
                }
                if !otherRows.isEmpty { credentialSection(L("Autres"), otherRows, empty: nil) }
                Section {
                    Toggle(L("Afficher les options avancées"), isOn: $showAdvanced)
                } footer: { Text(L("Les modifications sont enregistrées immédiatement. Les sessions actives récupèrent les nouvelles clés automatiquement.")) }
            }
        }.modernList().navigationTitle(L("Clés et identifiants")).navigationBarTitleDisplayMode(.inline)
            .task(id: scope) { await reload() }
            .refreshable { await reload() }
            .sheet(isPresented: $adding) {
                AccountsCustomKeySheet(store: store, profileTitle: profileTitle)
            }
    }

    @ViewBuilder private var voiceSection: some View {
        Section {
            NavigationLink {
                AccountsCredentialEditor(store: store, key: "ELEVENLABS_API_KEY", profileTitle: profileTitle,
                                         followUp: elevenFollowUp) { Task { await loadVoiceConfig() } }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform").font(.system(size: 20, weight: .medium)).foregroundStyle(AppTheme.accent)
                            .frame(width: 36, height: 36).background(AppTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("ElevenLabs")).font(.headline)
                            AccountsStatusLabel(set: eleven?.isSet == true, text: eleven?.status ?? L("Non définie"))
                        }
                    }
                    Text(L("Active la voix ElevenLabs en streaming (synthèse) et la transcription en temps réel Scribe. La clé reste sur votre serveur Hermes."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.vertical, 6)
            }.accessibilityIdentifier("credential-elevenlabs")
            if eleven?.isSet == true, ttsProvider != "elevenlabs" || sttProvider != "elevenlabs" {
                Button { voiceNotice = nil; offerVoice = true } label: {
                    Label(L("Utiliser ElevenLabs pour la voix"), systemImage: "speaker.wave.2")
                }.disabled(store.tools.busy || app.demo)
            }
            ForEach(voiceRows) { credentialLink($0) }
        } header: { Text(L("Voix et audio")) } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Synthèse vocale : %@ · Transcription : %@", providerName(ttsProvider, fallback: L("par défaut")), providerName(sttProvider, fallback: L("détection automatique"))))
                if let voiceNotice { Text(voiceNotice).foregroundStyle(AppTheme.accent) }
                Text(L("OpenAI et xAI partagent la clé de leur fournisseur de modèles."))
            }
        }
        .appConfirm(L("Utiliser ElevenLabs pour la voix de « %@ » ?", profileTitle), isPresented: $offerVoice) {
            ForEach(Array(elevenFollowUp.actions.enumerated()), id: \.offset) { _, action in
                Button(action.label) {
                    Task {
                        var ok = false
                        await store.tools.perform { try await action.run(); ok = true }
                        if ok { voiceNotice = action.done }
                    }
                }
            }
        } message: { Text(elevenFollowUp.message) }
    }
    @State private var offerVoice = false

    /// PUT /api/config — `tts.provider` / `stt.provider` (hermes_cli/config_defaults.py `tts`, `stt`).
    private var elevenFollowUp: AccountsFollowUp {
        let tools = store.tools
        let refresh: @MainActor () async -> Void = { await loadVoiceConfig() }
        return AccountsFollowUp(
            title: L("Faire d’ElevenLabs la voix de « %@ » ?", profileTitle),
            message: L("Hermes utilisera ElevenLabs pour lire ses réponses. Vous pouvez aussi lui confier la transcription (Scribe). Ce choix est enregistré dans la configuration de cet agent."),
            actions: [
                .init(label: L("Voix (synthèse) seulement"), done: "ElevenLabs est maintenant la voix de cet agent.") {
                    _ = try await tools.request("/api/config", method: "PUT", body: ["config": ["tts": ["provider": "elevenlabs"]]])
                    await refresh()
                },
                .init(label: L("Voix et transcription"), done: "ElevenLabs gère maintenant la voix et la transcription.") {
                    _ = try await tools.request("/api/config", method: "PUT",
                        body: ["config": ["tts": ["provider": "elevenlabs"], "stt": ["provider": "elevenlabs"]]])
                    await refresh()
                }
            ])
    }

    private func credentialSection(_ title: String, _ items: [AccountsCredential], empty: String?) -> some View {
        Section(title) {
            if items.isEmpty, let empty { Text(empty).font(.subheadline).foregroundStyle(.secondary) }
            ForEach(items) { credentialLink($0) }
        }
    }

    private func credentialLink(_ credential: AccountsCredential) -> some View {
        NavigationLink {
            AccountsCredentialEditor(store: store, key: credential.key, profileTitle: profileTitle,
                                     providerSetup: credential.category == "provider",
                                     followUp: credential.key == "ELEVENLABS_API_KEY" ? elevenFollowUp : nil)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(credential.title).font(.subheadline.weight(.medium))
                if credential.title != credential.key {
                    Text(credential.key).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                AccountsStatusLabel(set: credential.isSet, text: credential.status)
            }.padding(.vertical, 3)
        }.accessibilityIdentifier("credential-" + credential.key)
    }

    private func row(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(AppTheme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }

    private func providerName(_ value: String, fallback: String) -> String {
        value.isEmpty ? fallback : (["elevenlabs": L("ElevenLabs"), "openai": L("OpenAI"), "edge": L("Edge (gratuit)"), "xai": "xAI", "mistral": L("Mistral"),
                                     "groq": L("Groq"), "local": L("Locale"), "gemini": L("Gemini"), "minimax": L("MiniMax"), "deepinfra": L("DeepInfra")][value] ?? value)
    }

    private func reload() async {
        if store.tools.profile != scope {
            store = AccountsEnvStore(tools: NativeToolSession(app, profile: scope))
            ttsProvider = ""; sttProvider = ""; voiceNotice = nil
        }
        await store.load()
        await loadVoiceConfig()
    }

    private func loadVoiceConfig() async {
        if app.demo { ttsProvider = "edge"; return }
        guard let config = try? await store.tools.request("/api/config") else { return }
        ttsProvider = config["tts"]["provider"].string
        sttProvider = config["stt"]["provider"].string
    }
}

/// « Ajouter une clé personnalisée » — any valid env name, written like any other key.
private struct AccountsCustomKeySheet: View {
    let store: AccountsEnvStore
    let profileTitle: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""
    private var valid: Bool { Accounts.validEnvName(name) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("p. ex. MY_SERVICE_API_KEY"), text: $name).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: { Text(L("Nom de la variable")) } footer: {
                    if !name.isEmpty && !valid {
                        Text(L("Utilisez uniquement des lettres, des chiffres et des traits de soulignement (doit commencer par une lettre ou un trait de soulignement)."))
                            .foregroundStyle(AppTheme.accent)
                    }
                }
                Section {
                    SecureField(L("Valeur"), text: $value).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: { Text(L("Enregistrée dans le .env de « %@ » sur le serveur, jamais sur cet iPhone.", profileTitle)) }
                ToolFeedback(tools: store.tools)
            }.modernList().navigationTitle(L("Clé personnalisée")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    AppToolbarItem(placement: .cancellationAction) { Button(L("Annuler")) { value = ""; dismiss() } }
                    AppToolbarItem(placement: .confirmationAction) {
                        Button(L("Ajouter")) {
                            Task { if await store.save(name, value: value) { value = ""; dismiss() } }
                        }.disabled(!valid || value.trimmingCharacters(in: .whitespaces).isEmpty || store.tools.busy)
                    }
                }
        }.presentationBackground(AppTheme.background)
    }
}
