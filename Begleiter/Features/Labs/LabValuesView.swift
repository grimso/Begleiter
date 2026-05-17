import SwiftData
import SwiftUI

/// Top-level "Blutwerte" screen. Presented as a sheet from the
/// `TimelineView` toolbar (sibling to Briefing / Handoff). Lists one
/// card per lab parameter found across all extracted journal entries
/// and navigates into `LabParameterDetailView` for a deep dive.
struct LabValuesView: View {
    let child: ChildState

    @Environment(\.dismiss) private var dismiss
    @State private var presentingAsk = false
    @State private var presentingPlotComposer = false

    @Query(sort: \JournalEntry.visitDate, order: .reverse)
    private var entries: [JournalEntry]

    var body: some View {
        let allSeries = LabSeries.aggregate(entries: entries)

        NavigationStack {
            Group {
                if allSeries.isEmpty {
                    emptyState
                } else {
                    populatedList(allSeries)
                }
            }
            .navigationTitle(L10n.key("labs.title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("app.done")) { dismiss() }
                }
            }
            .sheet(isPresented: $presentingAsk) {
                AskView(child: child, scope: .labs)
            }
            .sheet(isPresented: $presentingPlotComposer) {
                LabPlotComposerView(child: child)
            }
            .scrollContentBackground(.hidden)
            .background(Color("BegleiterBackground").ignoresSafeArea())
        }
    }

    // MARK: - Populated

    @ViewBuilder
    private func populatedList(_ allSeries: [LabSeries]) -> some View {
        let measurementCount = allSeries.reduce(0) { $0 + $1.points.count }
        let entriesWithLabs = entries.filter {
            !($0.extractedFields.labValues?.value.isEmpty ?? true)
        }.count
        let latestDate = allSeries.compactMap { $0.latest?.date }.max()

        List {
            Section {
                if let latestDate {
                    Text(String(format: L10n.t("labs.header.lastMeasured"),
                                latestDate.formatted(date: .abbreviated, time: .omitted)))
                        .font(.subheadline)
                }
                Text(String(format: L10n.t("labs.header.summary"),
                            measurementCount, entriesWithLabs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color("BegleiterCardSurface"))

            Section {
                Button {
                    presentingAsk = true
                } label: {
                    HStack {
                        Image(systemName: "bubble.left.and.text.bubble.right.fill")
                        Text(L10n.key("labs.ask.cta"))
                            .fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.accentColor.opacity(0.12))
                .accessibilityLabel(L10n.t("labs.ask.cta"))

                Button {
                    presentingPlotComposer = true
                } label: {
                    HStack {
                        Image(systemName: "chart.bar.xaxis")
                        Text(L10n.key("labs.plotComposer.cta"))
                            .fontWeight(.semibold)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.purple.opacity(0.12))
                .accessibilityLabel(L10n.t("labs.plotComposer.cta"))
            }

            Section {
                ForEach(allSeries) { series in
                    NavigationLink {
                        LabParameterDetailView(series: series)
                    } label: {
                        LabSeriesCard(series: series)
                    }
                    .listRowBackground(Color("BegleiterCardSurface"))
                }
            }
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.t("labs.empty.title"), systemImage: "testtube.2")
        } description: {
            Text(L10n.key("labs.empty.body"))
        } actions: {
            Button {
                dismiss()
            } label: {
                Text(L10n.key("labs.empty.action"))
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// One row in `LabValuesView` — parameter label, latest value, mini
/// sparkline, trend arrow, reference-range badge.
private struct LabSeriesCard: View {
    let series: LabSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(series.germanLabel)
                        .font(.subheadline.bold())
                    Text(series.parameter)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let latest = series.latest {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(formatted(latest.value))
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(series.isLatestOutOfRange ? .orange : .primary)
                        Text(series.unit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        trendIndicator
                    }
                }
            }

            // Mini sparkline. Only meaningful with ≥2 points; the chart
            // happily renders 1 too (a single dot) but we hide it then to
            // keep the row visually quiet.
            if series.points.count >= 2 {
                LabValueChart(
                    parameter: series.parameter,
                    points: series.points.map { point in
                        LabValueChart.Point(
                            id: point.id,
                            date: point.date,
                            value: point.value,
                            isHighlighted: point.id == series.latest?.id
                        )
                    },
                    referenceBand: referenceBand,
                    height: 60,
                    xAxisDayStride: xAxisDayStride
                )
            }

            if let refMin = series.referenceMin, let refMax = series.referenceMax {
                Text(String(format: L10n.t("labs.referenceRange"),
                            formatted(refMin), formatted(refMax), series.unit))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trendIndicator: some View {
        switch series.trend {
        case .up:
            Image(systemName: "arrow.up.right")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.t("labs.trend.up"))
        case .down:
            Image(systemName: "arrow.down.right")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.t("labs.trend.down"))
        case .stable:
            Image(systemName: "arrow.right")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.t("labs.trend.stable"))
        }
    }

    private var referenceBand: (min: Double, max: Double)? {
        guard let min = series.referenceMin, let max = series.referenceMax else { return nil }
        return (min, max)
    }

    private var xAxisDayStride: Int {
        guard let first = series.points.first, let last = series.points.last else { return 7 }
        let days = Calendar.current.dateComponents([.day], from: first.date, to: last.date).day ?? 0
        switch days {
        case ..<35:   return 7
        case ..<120:  return 14
        default:      return 30
        }
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
