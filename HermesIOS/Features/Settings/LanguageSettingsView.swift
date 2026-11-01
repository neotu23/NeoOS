import SwiftUI

/// « Langue » — the interface language, applied to every screen without relaunching.
struct LanguageSettingsView: View {
    private let localizer = Localizer.shared

    var body: some View {
        List {
            Section {
                ForEach(AppLanguage.allCases) { language in
                    Button { localizer.select(language) } label: {
                        HStack(spacing: 13) {
                            Text(verbatim: language.autonym).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Image(systemName: localizer.language == language ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(localizer.language == language ? AppTheme.accent : .secondary)
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityValue(localizer.language == language ? L("Sélectionnée") : "")
                        .accessibilityIdentifier("language-\(language.rawValue)")
                }
            } header: {
                Text(L("Langue de l’interface"))
            } footer: {
                Text(L("Le changement s’applique immédiatement à toute l’application et reste enregistré sur cet iPhone. Le français est la langue d’origine : les textes non traduits y restent affichés en français."))
                    .font(.footnote)
            }
        }.modernList()
            .navigationTitle(L("Langue")).navigationBarTitleDisplayMode(.inline)
    }
}
