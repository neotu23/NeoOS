import SwiftUI

/// « Connexions » — the Hermes servers saved on this iPhone.
struct ConnectionsView: View {
    @Bindable var model: AppModel
    @State private var adding = false
    @State private var reconnecting: SavedConnection?
    @State private var removing: SavedConnection?
    @State private var guide = false
    var body: some View {
        List {
            Section {
                ForEach(model.connections) { connection in
                    VStack(alignment: .leading, spacing: 9) {
                        Button { Task { await model.activate(connection) } } label: {
                            HStack {
                                Image(systemName: "server.rack").foregroundStyle(AppTheme.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(connection.name).foregroundStyle(.primary)
                                    Text(connection.endpoint.baseURL.host ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.activeConnection?.id == connection.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.accent).accessibilityLabel(L("Serveur actif"))
                                }
                            }
                        }
                        HStack {
                            Button(L("Se reconnecter")) { reconnecting = connection }.font(.caption)
                            Spacer()
                            Button(L("Retirer"), role: .destructive) { removing = connection }.font(.caption)
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 5)
                }
                Button { adding = true } label: { Label(L("Connecter un Hermes"), systemImage: "plus") }
            } header: { Text(L("Vos serveurs")) } footer: {
                Text(L("Chaque serveur a ses propres agents. Retirer une connexion efface son cache local, sans toucher au serveur.")).font(.footnote)
            }
            Section {
                Button { guide = true } label: { Label(L("Guide Tailscale & Hermes"), systemImage: "book") }
            }
            if model.demo {
                Section { Button(L("Quitter l’aperçu")) { model.demo = false; model.selected = nil; model.profiles = []; model.transcript = Transcript() } }
            }
        }.modernList()
            .navigationTitle(L("Connexions")).navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $adding) { OnboardingView(model: model, adding: true) }
            .sheet(item: $reconnecting) { OnboardingView(model: model, adding: true, existing: $0) }
            .sheet(isPresented: $guide) { ConnectionGuide() }
            .appConfirm(L("Retirer cette connexion et son cache de cet iPhone ?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button(L("Retirer de cet iPhone"), role: .destructive) {
                    if let connection = removing { Task { await model.removeConnection(connection) } }
                    removing = nil
                }
            }
    }
}

/// « À propos » — what the app is, where its code lives, its version.
struct AboutView: View {
    let model: AppModel
    var body: some View {
        List {
            Section {
                HStack(spacing: 17) {
                    AgentMark(size: 48)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("NeoOS")).font(.system(size: 28, weight: .semibold, design: .rounded))
                        Text(L("Moins de bruit. Plus de conversation.")).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 14)
            }.listRowBackground(Color.clear)
            Section(L("Simple, par nature")) {
                Label(L("Interface native SwiftUI"), systemImage: "iphone")
                Label(L("Connexion directe à votre serveur"), systemImage: "point.3.connected.trianglepath.dotted")
                Label(L("Aucun compte NeoOS, aucune télémétrie"), systemImage: "hand.raised")
            }.font(.subheadline)
            Section {
                Link(destination: URL(string: "https://github.com/Molliex05/hermes-ios")!) { Label(L("Code source"), systemImage: "chevron.left.forwardslash.chevron.right") }
                Link(destination: URL(string: "https://hermes-agent.nousresearch.com/docs/")!) { Label(L("Documentation Hermes"), systemImage: "arrow.up.right.square") }
                HStack { Text(L("Version")); Spacer(); Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0").foregroundStyle(.secondary) }
            } footer: {
                Text(L("NeoOS est un client communautaire indépendant pour Hermes Agent de Nous Research. Les conversations sont mises en cache sur cet appareil.")).font(.footnote)
            }
        }.modernList()
            .navigationTitle(L("À propos")).navigationBarTitleDisplayMode(.inline)
    }
}
