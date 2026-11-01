import SwiftUI

/// « Gérer et créer » — every Hermes profile of the active server, hidden ones included. Each opens its settings.
/// Roster: `profiles.list` (AppModel.refreshProfiles); identity: `profiles.configure`;
/// create: `profiles.create`; rename: `PATCH /api/profiles/{name}`; delete: `DELETE /api/profiles/{name}`
/// (tui_gateway/methods_profiles.py, hermes_cli/web_routers/profiles.py).
struct AgentsHubView: View {
    let app: AppModel
    @State private var search = ""
    @State private var creating = false
    @State private var deleting: AgentProfile?
    @State private var error: String?

    init(app: AppModel) { self.app = app }

    private var agents: [AgentProfile] {
        app.profiles.filter { search.isEmpty || "\($0.title) \($0.name) \($0.detail)".localizedCaseInsensitiveContains(search) }
            .sorted { ($0.pinned == true ? 0 : 1, $0.hidden == true ? 1 : 0) < ($1.pinned == true ? 0 : 1, $1.hidden == true ? 1 : 0) }
    }
    private var canAct: Bool { app.demo || app.state == .connected }

    var body: some View {
        List {
            AppSearchSection(text: $search, prompt: L("Rechercher des profils…"))
            Section {
                ForEach(agents) { agent in
                    NavigationLink { AgentSettingsView(app: app, profile: agent.name) } label: { agentRow(agent) }
                        .swipeActions(edge: .leading) {
                            Button(L("Discuter"), systemImage: "bubble.left") { open(agent) }.tint(AppTheme.colors[1])
                            Button(agent.pinned == true ? L("Détacher") : L("Épingler"), systemImage: agent.pinned == true ? "pin.slash" : "pin") {
                                presentation(agent, pinned: agent.pinned != true, hidden: agent.hidden == true)
                            }.tint(AppTheme.accent)
                        }
                        .swipeActions(edge: .trailing) {
                            if agent.name != "default" { Button(L("Supprimer"), systemImage: "trash", role: .destructive) { deleting = agent } }
                            Button(agent.hidden == true ? L("Afficher") : L("Masquer"), systemImage: agent.hidden == true ? "eye" : "eye.slash") {
                                presentation(agent, pinned: agent.pinned == true, hidden: agent.hidden != true)
                            }
                        }
                        .disabled(!canAct)
                }
                if app.profiles.isEmpty && !app.demo && app.state != .offline {
                    SkeletonRows(count: 3)
                } else if app.profiles.isEmpty {
                    Text(app.demo ? L("Connectez votre Hermes pour gérer vos agents.") : L("Aucun profil pour le moment.")).font(.subheadline).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Label(app.activeConnection?.name ?? (app.demo ? L("Aperçu") : L("Hermes")), systemImage: "server.rack")
                    Spacer()
                    Text(L("%lld profils", app.profiles.count))
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !app.demo && app.state != .connected { ConnectionIndicator(model: app) }
                    if let error { Text(error).foregroundStyle(AppTheme.accent) }
                    Text(L("Chaque agent est un profil Hermes : sa personnalité, son modèle, ses clés et ses canaux lui appartiennent."))
                }.font(.footnote)
            }
            Section {
                Button { creating = true } label: { Label(L("Nouvel agent"), systemImage: "plus") }.disabled(app.demo || app.state != .connected)
            }
        }.modernList().navigationTitle(L("Gérer mes agents")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel(L("Nouvel agent"))
                        .disabled(app.demo || app.state != .connected)
                }
            }
            .task { await refresh() }
            .refreshable { await refresh() }
            .sheet(isPresented: $creating) { AccountsAgentCreator(app: app) }
            .appConfirm(L("Supprimer définitivement %@ ?", deleting?.title ?? ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(L("Supprimer l’agent et ses données"), role: .destructive) {
                    guard let agent = deleting, agent.name != "default" else { return }; deleting = nil
                    Task { do { try await app.deleteBot(agent.name) } catch { self.error = error.localizedDescription } }
                }
            } message: { Text(L("Hermes supprimera ce profil, son historique, ses skills, ses clés et sa configuration sur le serveur.")) }
    }

    private func agentRow(_ agent: AgentProfile) -> some View {
        let unread = app.hasUnread(profile: agent.name)
        return HStack(spacing: 13) {
            AgentAvatar(name: agent.name, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(agent.title).font(.subheadline.weight(unread ? .semibold : .medium)).lineLimit(1)
                    if agent.pinned == true { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(AppTheme.accent).accessibilityLabel(L("Épinglé")) }
                    if agent.hidden == true { Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.secondary).accessibilityLabel(L("Masqué")) }
                }
                Text(["@\(agent.name)", agent.model].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !agent.detail.isEmpty { Text(agent.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if unread { Circle().fill(AppTheme.accent).frame(width: 7, height: 7).accessibilityLabel(L("Non lu")) }
            if app.profile == agent.name { Text(L("Actif")).font(.caption2.weight(.semibold)).foregroundStyle(AppTheme.accent) }
        }.padding(.vertical, 4).accessibilityIdentifier("hub-agent-" + agent.name)
    }

    private func presentation(_ agent: AgentProfile, pinned: Bool, hidden: Bool) {
        guard !app.demo else { return }
        Task {
            do { try await app.editBotPresentation(name: agent.name, title: agent.title, pinned: pinned, hidden: hidden); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }

    @Environment(\.returnToChat) private var returnToChat
    private func open(_ agent: AgentProfile) {
        returnToChat?()
        Task { await app.openBot(agent) }
    }

    private func refresh() async {
        guard !app.demo, app.state == .connected else { return }
        do { try await app.refreshProfiles(); error = nil } catch { self.error = error.localizedDescription }
    }
}

/// How one agent appears in NeoOS (Bot Mode title, pin, visibility), plus rename and delete.
/// Role and SOUL.md live in « Mémoire et personnalité ».
struct AgentIdentityView: View {
    let app: AppModel
    let name: String
    /// Pops the settings of an agent that no longer exists under this name.
    var removed: () -> Void
    @State private var title = ""
    @State private var pinned = false
    @State private var hidden = false
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var saved = false
    @State private var deleting = false
    @State private var renaming = false
    @State private var newName = ""
    private var agent: AgentProfile? { app.profiles.first { $0.name == name } }
    private var isCurrent: Bool { app.profile == name }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AgentAvatar(name: name, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(agent?.title ?? name).font(.title3.weight(.medium))
                        Text("@\(name)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let agent, !agent.model.isEmpty {
                            Text([agent.model, agent.provider].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        if let agent, agent.skillCount > 0 { Text(L("%lld skills", agent.skillCount)).font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(.vertical, 6)
            }
            Section {
                TextField(L("Nom affiché"), text: $title)
                Toggle(L("Épingler cet agent"), isOn: $pinned)
                Toggle(L("Masquer des listes d’agents"), isOn: $hidden)
            } header: { Text(L("Dans Bot Mode")) } footer: {
                Text(L("Un agent masqué reste disponible : « Afficher les agents masqués » dans le menu le fait réapparaître.")).font(.footnote)
            }
            if let error { Section { Text(error).foregroundStyle(AppTheme.accent) } }
            if saved { Section { Label(L("Enregistré"), systemImage: "checkmark.circle").foregroundStyle(.green) } }
            if name != "default" {
                Section {
                    Button(L("Renommer…")) { newName = name; renaming = true }.disabled(busy || app.demo || isCurrent)
                    Button(L("Supprimer cet agent"), role: .destructive) { deleting = true }.disabled(busy || app.demo)
                } footer: {
                    if isCurrent { Text(L("Ouvrez un autre agent pour renommer celui-ci : sa conversation est en cours.")).font(.footnote) }
                }
            } else {
                Section { } footer: { Text(L("Hermes est le profil principal de ce serveur. Il ne peut être ni renommé ni supprimé.")).font(.footnote) }
            }
        }.modernList().navigationTitle(L("Identité")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .confirmationAction) {
                    Button(busy ? L("En cours…") : L("Enregistrer")) { Task { await save() } }.disabled(busy || !loaded || app.demo)
                }
            }
            .task {
                guard !loaded, let agent else { return }
                title = agent.title; pinned = agent.pinned == true; hidden = agent.hidden == true; loaded = true
            }
            .appAlert("Renommer \(agent?.title ?? name)", isPresented: $renaming) {
                TextField(L("Nouveau nom"), text: $newName).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(L("Renommer")) { Task { await rename() } }
                Button(L("Annuler"), role: .cancel) { }
            } message: { Text(L("Lettres minuscules, chiffres, tirets et underscores. Hermes arrête puis renomme le profil et ses canaux.")) }
            .appConfirm(L("Supprimer définitivement cet agent ?"), isPresented: $deleting) {
                Button(L("Supprimer l’agent et ses données"), role: .destructive) {
                    busy = true
                    Task {
                        do { try await app.deleteBot(name); removed() } catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }
            } message: { Text(L("Hermes supprimera ce profil, son historique, ses skills, ses clés et sa configuration sur le serveur.")) }
    }

    private func save() async {
        busy = true; error = nil; saved = false
        defer { busy = false }
        do {
            try await app.editBotPresentation(name: name, title: title.trimmingCharacters(in: .whitespaces), pinned: pinned, hidden: hidden)
            saved = true
        } catch { self.error = error.localizedDescription }
    }

    private func rename() async {
        let target = newName.trimmingCharacters(in: .whitespaces).lowercased()
        guard target != name else { return }
        guard Accounts.validProfileName(target) else { error = L("Lettres minuscules, chiffres, tirets et underscores. Doit commencer par une lettre ou un chiffre."); return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let tools = NativeToolSession(app, profile: name)
            _ = try await tools.request("/api/profiles/" + Accounts.segment(name), method: "PATCH", body: ["new_name": .string(target)])
            try await app.refreshProfiles()
            removed()
        } catch { self.error = error.localizedDescription }
    }
}

/// « Nouvel agent » — blank or cloned, with the desktop/CLI create options (`profiles.create`).
private struct AccountsAgentCreator: View {
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var tools: NativeToolSession
    @State private var name = ""
    @State private var detail = ""
    @State private var soul = ""
    @State private var clone = "default"
    @State private var cloneAll = false
    @State private var cloneChannels = false
    @State private var noSkills = false
    @State private var provider = ""
    @State private var model = ""
    @State private var options: [JSONValue] = []
    @State private var busy = false
    @State private var error: String?

    init(app: AppModel) {
        self.app = app
        _tools = State(initialValue: NativeToolSession(app, profile: app.profile))
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespaces).lowercased() }
    private var validName: Bool { Accounts.validProfileName(cleanName) && cleanName != "default" && !app.profiles.contains { $0.name == cleanName } }
    private var providerModels: [String] {
        options.first { $0["slug"].string == provider }?["models"].array.map { $0.string.isEmpty ? $0["id"].string : $0.string }.filter { !$0.isEmpty } ?? []
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("Nom du profil (ex. chercheur)"), text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(L("Son rôle, en quelques mots"), text: $detail, axis: .vertical).lineLimit(2...4)
                } header: { Text(L("Identité")) } footer: {
                    Text(!name.isEmpty && !validName ? L("Lettres minuscules, chiffres, tirets et underscores, unique sur ce serveur. Doit commencer par une lettre ou un chiffre.") : L("Ce profil sera disponible dans toutes vos interfaces Hermes.")).font(.footnote)
                        .foregroundStyle(!name.isEmpty && !validName ? AppTheme.accent : .secondary)
                }
                Section {
                    AppPicker(title: L("Configuration"), selection: $clone,
                              options: [(value: "", label: L("Nouveau profil"))] + app.profiles.map { (value: $0.name, label: "Copier \($0.title)") })
                    if clone.isEmpty {
                        Toggle(L("Sans skills intégrés"), isOn: $noSkills)
                    } else {
                        Toggle(L("Tout copier (mémoire, sessions, état)"), isOn: $cloneAll)
                        Toggle(L("Copier aussi les canaux de messagerie"), isOn: $cloneChannels)
                    }
                } header: { Text(L("Point de départ")) } footer: {
                    Text(clone.isEmpty
                         ? L("Un profil vierge avec les skills intégrés, les identifiants de connexion du serveur et son modèle par défaut.")
                         : cloneChannels ? L("Attention : deux agents ne peuvent pas partager le même bot. Désactivez le canal sur l’un des deux.")
                         : L("Copie la configuration, les clés, SOUL.md et les skills. Les bots de messagerie ne sont pas copiés."))
                }
                Section {
                    AppPicker(title: L("Fournisseur"), selection: $provider,
                              options: [(value: "", label: L("Hérité"))] + options.map { (value: $0["slug"].string, label: $0["name"].string.isEmpty ? $0["slug"].string : $0["name"].string) })
                        .onChange(of: provider) { _, _ in model = providerModels.first ?? "" }
                    if !provider.isEmpty {
                        AppPicker(title: L("Modèle"), selection: $model,
                                  options: (providerModels.contains(model) ? [] : [(value: model, label: model.isEmpty ? L("Choisir") : model)]) + providerModels.map { (value: $0, label: $0) })
                    }
                } header: { Text(L("Modèle")) } footer: { Text(L("Laissez « Hérité » pour reprendre le modèle de la configuration copiée ou du serveur.")).font(.footnote) }
                Section { TextEditor(text: $soul).frame(minHeight: 140) } header: { Text(L("Personnalité · SOUL.md")) } footer: { Text(L("Laissez vide pour conserver la personnalité copiée ou celle par défaut.")).font(.footnote) }
                if let error { Section { Text(error).foregroundStyle(AppTheme.accent) } }
            }.modernList().navigationTitle(L("Un nouvel agent")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    AppToolbarItem(placement: .cancellationAction) { Button(L("Annuler")) { dismiss() }.disabled(busy) }
                    AppToolbarItem(placement: .confirmationAction) {
                        Button(busy ? L("Création…") : L("Créer")) { Task { await create() } }
                            .disabled(busy || !validName || app.demo || (!provider.isEmpty && model.isEmpty))
                    }
                }
                .interactiveDismissDisabled(busy)
                .task {
                    guard !app.demo, options.isEmpty else { return }
                    options = ((try? await tools.request("/api/model/options"))?["providers"].array ?? []).filter { !$0["models"].array.isEmpty }
                }
        }.presentationBackground(AppTheme.background)
    }

    private func create() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let extras = cloneAll || cloneChannels || noSkills || !provider.isEmpty
            if extras {
                var params: [String: JSONValue] = ["name": .string(cleanName), "description": .string(detail), "soul": .string(soul),
                                                   "share_auth": true, "no_alias": true]
                if !clone.isEmpty {
                    params["clone_from"] = .string(clone)
                    if cloneAll { params["clone_all"] = true }
                    if cloneChannels { params["clone_channels"] = true }
                } else if noSkills { params["no_skills"] = true }
                if !provider.isEmpty, !model.isEmpty { params["provider"] = .string(provider); params["model"] = .string(model) }
                _ = try await tools.request("profiles.create", body: .object(params), rpc: true)
                try await app.refreshProfiles()
            } else {
                try await app.createBot(name: cleanName, description: detail, soul: soul, clone: clone)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
