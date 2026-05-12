import SwiftData
import SwiftUI

/// Per-parameter deep dive shown when the parent taps a card on
/// `LabValuesView`. Renders the full history as a large chart with a
/// reference band (when available) and lists every measurement with a
/// link back to the journal entry it came from.
struct LabParameterDetailView: View {
    let series: LabSeries

    /// All entries are queried so we can deep-link each measurement back
    /// to its source `JournalEntry` via `EntryDetailView`.
    @Query(sort: \JournalEntry.visitDate, order: .reverse)
    private var allEntries: [JournalEntry]

    var body: some View {
        Form {
            Section {
                LabValueChart(
                    parameter: series.parameter,
                    points: chartPoints,
                    referenceBand: referenceBand,
                    height: 200,
                    xAxisDayStride: xAxisDayStride
                )
                .padding(.vertical, 4)
            } header: {
                Text(L10n.key("labs.detail.history"))
            } footer: {
                if let refMin = series.referenceMin, let refMax = series.referenceMax {
                    Text(String(format: L10n.t("labs.referenceRange"),
                                formatted(refMin), formatted(refMax), series.unit))
                }
            }

            Section {
                ForEach(series.points.reversed()) { point in
                    measurementRow(point)
                }
            } header: {
                Text(L10n.key("labs.detail.measurements"))
            } footer: {
                Text(L10n.key("labs.detail.measurements.footer"))
            }
        }
        .navigationTitle(series.germanLabel)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Rendering helpers

    private var chartPoints: [LabValueChart.Point] {
        let latestId = series.latest?.id
        return series.points.map { point in
            LabValueChart.Point(
                id: point.id,
                date: point.date,
                value: point.value,
                isHighlighted: point.id == latestId
            )
        }
    }

    private var referenceBand: (min: Double, max: Double)? {
        guard let min = series.referenceMin, let max = series.referenceMax else { return nil }
        return (min, max)
    }

    /// Pick an x-axis stride wide enough that the labels don't overlap.
    private var xAxisDayStride: Int {
        guard let first = series.points.first, let last = series.points.last else { return 7 }
        let days = Calendar.current.dateComponents([.day], from: first.date, to: last.date).day ?? 0
        switch days {
        case ..<35:   return 7
        case ..<120:  return 14
        default:      return 30
        }
    }

    @ViewBuilder
    private func measurementRow(_ point: LabPoint) -> some View {
        if let entry = allEntries.first(where: { $0.entryId == point.sourceEntryId }) {
            NavigationLink {
                EntryDetailView(entry: entry)
            } label: {
                row(for: point)
            }
        } else {
            row(for: point)
        }
    }

    @ViewBuilder
    private func row(for point: LabPoint) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(point.date, style: .date)
                    .font(.subheadline)
                Text(sourceLabel(point.source))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(formatted(point.value)) \(series.unit)")
                .font(.body.monospacedDigit())
                .foregroundStyle(isOutOfRange(point) ? .orange : .primary)
        }
    }

    private func isOutOfRange(_ point: LabPoint) -> Bool {
        if let min = series.referenceMin, point.value < min { return true }
        if let max = series.referenceMax, point.value > max { return true }
        return false
    }

    private func sourceLabel(_ source: LabValue.Source) -> String {
        switch source {
        case .befundPhoto: return L10n.t("labs.source.befund")
        case .voice:       return L10n.t("labs.source.voice")
        case .text:        return L10n.t("labs.source.text")
        case .manual:      return L10n.t("labs.source.manual")
        }
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
