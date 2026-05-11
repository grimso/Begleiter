import SwiftUI

/// Minimal placeholder shown after onboarding has been completed.
///
/// Iteration 1's success criterion is "onboarding writes a valid ChildState
/// and the next launch lands here showing the persisted phase + day". The
/// real timeline / capture / briefing views land in the next iterations.
struct HomePlaceholderView: View {
    let child: ChildState

    var body: some View {
        let info = child.currentPhaseInfo()

        return NavigationStack {
            Form {
                Section {
                    LabeledContent(
                        L10n.t("home.placeholder.phaseLabel"),
                        value: NSLocalizedString("phase.\(info.phase.rawValue).label", comment: "")
                    )
                    LabeledContent(
                        L10n.t("home.placeholder.dayLabel"),
                        value: "\(info.dayInPhase)"
                    )
                    LabeledContent(
                        L10n.t("home.placeholder.diagnosisDays"),
                        value: "\(child.daysSinceDiagnosis())"
                    )
                } header: {
                    Text(L10n.key("home.placeholder.subtitle"))
                }

                Section {
                    NavigationLink {
                        SmokeTestView()
                    } label: {
                        Label(L10n.t("debug.smoke.title"), systemImage: "brain.head.profile")
                    }
                } header: {
                    Text(L10n.key("debug.section"))
                }
            }
            .navigationTitle(L10n.key("home.placeholder.title"))
        }
    }
}
