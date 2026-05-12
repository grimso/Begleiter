import SwiftUI

/// Compact card rendered above the journal timeline that surfaces the
/// three most recent priority blood-count values (ANC, PLT, Hb…) so the
/// parent sees the latest counts at-a-glance whenever they open the app.
///
/// Hidden entirely if there are no extracted lab values, or if the most
/// recent measurement is older than 14 days. The whole pill is tappable
/// and opens `LabValuesView`.
struct LabStatusPill: View {
    let series: [LabSeries]
    let now: Date
    var onTap: () -> Void

    /// Don't render the pill if the freshest measurement is older than
    /// this. Keeps the timeline visually quiet when labs are stale.
    private let freshnessWindowDays = 14

    init(series: [LabSeries], now: Date = .now, onTap: @escaping () -> Void) {
        self.series = series
        self.now = now
        self.onTap = onTap
    }

    var body: some View {
        if let snapshot = makeSnapshot() {
            Button(action: onTap) {
                content(snapshot)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.key("labs.pill.title"))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text("· \(snapshot.freshnessLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                ForEach(snapshot.entries) { entry in
                    valueChip(entry)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func valueChip(_ entry: SnapshotEntry) -> some View {
        HStack(spacing: 4) {
            Text(entry.parameter)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text(entry.formattedValue)
                .font(.subheadline.monospacedDigit().bold())
                .foregroundStyle(entry.isOutOfRange ? .orange : .primary)
            trendIcon(entry.trend)
        }
    }

    @ViewBuilder
    private func trendIcon(_ trend: TrendDirection) -> some View {
        switch trend {
        case .up:
            Image(systemName: "arrow.up.right")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
        case .down:
            Image(systemName: "arrow.down.right")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
        case .stable:
            Image(systemName: "arrow.right")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Snapshot

    private struct Snapshot {
        let entries: [SnapshotEntry]
        let freshnessLabel: String
    }

    private struct SnapshotEntry: Identifiable {
        let id: String
        let parameter: String
        let formattedValue: String
        let isOutOfRange: Bool
        let trend: TrendDirection
    }

    private func makeSnapshot() -> Snapshot? {
        // Up to three priority parameters, only those that exist.
        let priority = ["ANC", "PLT", "HB", "WBC"]
        let byParam = Dictionary(uniqueKeysWithValues: series.map { ($0.parameter, $0) })
        let picks = priority.compactMap { byParam[$0] }.prefix(3)
        guard !picks.isEmpty else { return nil }

        // Freshness window: hide entirely if the latest measurement across
        // the picked series is older than 14 days.
        let latestDate = picks.compactMap { $0.latest?.date }.max()
        guard let latestDate else { return nil }
        let days = Calendar.current.dateComponents([.day], from: latestDate, to: now).day ?? 0
        guard days <= freshnessWindowDays else { return nil }

        let entries = picks.map { series -> SnapshotEntry in
            let latest = series.latest!
            return SnapshotEntry(
                id: series.parameter,
                parameter: series.parameter,
                formattedValue: String(format: "%g", latest.value),
                isOutOfRange: series.isLatestOutOfRange,
                trend: series.trend
            )
        }

        return Snapshot(entries: entries, freshnessLabel: freshnessLabel(daysAgo: days))
    }

    private func freshnessLabel(daysAgo: Int) -> String {
        switch daysAgo {
        case ..<1:  return L10n.t("labs.pill.daysAgo.today")
        case 1:     return L10n.t("labs.pill.daysAgo.one")
        default:    return String(format: L10n.t("labs.pill.daysAgo.other"), daysAgo)
        }
    }
}
