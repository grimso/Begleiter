import SwiftUI

/// Landing page for the Profile tab. Two pushable destinations:
/// - **Behandlung** → `ClinicalSettingsView` (user-facing clinical state)
/// - **Entwicklung** → `SettingsView` (developer toggles + diagnostics)
///
/// Kept intentionally small — no toggles or live state here, just routing.
struct ProfileLandingView: View {
    let child: ChildState

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ClinicalSettingsView(child: child)
                } label: {
                    landingRow(
                        icon: "stethoscope",
                        titleKey: "settings.profile.behandlung",
                        subtitleKey: "settings.profile.behandlung.description"
                    )
                }
                NavigationLink {
                    SettingsView()
                } label: {
                    landingRow(
                        icon: "wrench.and.screwdriver",
                        titleKey: "settings.profile.entwicklung",
                        subtitleKey: "settings.profile.entwicklung.description"
                    )
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color("BegleiterBackground").ignoresSafeArea())
        .listRowBackground(Color("BegleiterCardSurface"))
        .navigationTitle(L10n.key("settings.profile.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func landingRow(
        icon: String,
        titleKey: String,
        subtitleKey: String
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.key(titleKey))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(L10n.key(subtitleKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(Color("BegleiterPrimary"))
        }
    }
}
