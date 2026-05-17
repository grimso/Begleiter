import SwiftUI

/// Placeholder Insights tab. Holds the slot for later iterations that will
/// surface aggregate trends (lab parameter series, treatment-phase progress,
/// adherence summaries). For now a `ContentUnavailableView` explains the
/// intent so the tab isn't a confusing blank.
struct InsightsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(L10n.key("insights.title"), systemImage: "chart.line.uptrend.xyaxis")
            } description: {
                Text(L10n.key("insights.description"))
            }
            .background(Color("BegleiterBackground").ignoresSafeArea())
            .navigationTitle(L10n.key("insights.title"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
