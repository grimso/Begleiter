import Charts
import SwiftData
import SwiftUI

/// Insights tab — at-a-glance lab status pill plus four small trend
/// charts (WBC, ANC, PLT, HB) over an adjustable window (1W / 4W / 12W /
/// Alle, default 4W).
///
/// Empty until at least one journal entry with extracted lab values is
/// processed; falls back to `ContentUnavailableView` with a hint.
struct InsightsView: View {
    let child: ChildState

    @Query(sort: \JournalEntry.visitDate, order: .reverse) private var entries: [JournalEntry]
    @State private var window: TimeWindow = .fourWeeks
    @State private var presentingLabs = false

    /// Priority parameters charted on the Insights tab. WBC and ANC are the
    /// two values clinicians watch most closely during chemotherapy phases;
    /// PLT and HB complete the standard blood-count quartet.
    private let priorityParameters = ["WBC", "ANC", "PLT", "HB"]

    var body: some View {
        let allSeries = LabSeries.aggregate(entries: entries)
        let availableSeries = priorityParameters.compactMap { code in
            allSeries.first(where: { $0.parameter == code })
        }

        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if !allSeries.isEmpty {
                        LabStatusPill(series: allSeries) {
                            presentingLabs = true
                        }
                        .frame(maxWidth: .infinity)
                    }

                    if availableSeries.isEmpty {
                        emptyState
                    } else {
                        windowPicker
                        VStack(spacing: 12) {
                            ForEach(availableSeries) { series in
                                chartCard(for: series)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .background(Color("BegleiterBackground").ignoresSafeArea())
            .navigationTitle(L10n.key("insights.title"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $presentingLabs) {
                LabValuesView(child: child)
            }
        }
    }

    // MARK: - Sub-views

    private var windowPicker: some View {
        Picker(L10n.t("insights.windowLabel"), selection: $window) {
            ForEach(TimeWindow.orderedCases, id: \.self) { w in
                Text(L10n.key(w.labelKey)).tag(w)
            }
        }
        .pickerStyle(.segmented)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.key("insights.empty.title"),
                  systemImage: "chart.line.uptrend.xyaxis")
        } description: {
            Text(L10n.key("insights.empty.description"))
        }
        .padding(.top, 40)
    }

    private func chartCard(for series: LabSeries) -> some View {
        let points = filteredPoints(series)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.parameter)
                    .font(.headline)
                    .foregroundStyle(Color("BegleiterPrimary"))
                Text(series.germanLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if let latest = series.latest {
                    Text(latestLabel(latest, unit: series.unit))
                        .font(.subheadline.monospacedDigit().bold())
                        .foregroundStyle(Color("BegleiterPrimary"))
                }
            }

            if points.isEmpty {
                Text(L10n.key("insights.noPointsInWindow"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            } else {
                LabValueChart(
                    parameter: series.parameter,
                    points: points,
                    referenceBand: nil,
                    height: 120,
                    xAxisDayStride: window.xAxisDayStride
                )
            }
        }
        .padding(14)
        .background(Color("BegleiterCardSurface"))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color("BegleiterDivider"), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Helpers

    private func filteredPoints(_ series: LabSeries) -> [LabValueChart.Point] {
        let allPoints = series.points.map { p in
            LabValueChart.Point(id: p.id, date: p.date, value: p.value, isHighlighted: false)
        }
        guard let days = window.days else { return allPoints }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        return allPoints.filter { $0.date >= cutoff }
    }

    private func latestLabel(_ point: LabPoint, unit: String) -> String {
        let value = String(format: "%g", point.value)
        return unit.isEmpty ? value : "\(value) \(unit)"
    }
}

// MARK: - Window enum

extension InsightsView {
    enum TimeWindow: Hashable, CaseIterable {
        case oneWeek, fourWeeks, twelveWeeks, all

        /// Display order in the segmented picker.
        static let orderedCases: [TimeWindow] = [.oneWeek, .fourWeeks, .twelveWeeks, .all]

        /// Window length in days, or nil for "all time".
        var days: Int? {
            switch self {
            case .oneWeek:     return 7
            case .fourWeeks:   return 28
            case .twelveWeeks: return 84
            case .all:         return nil
            }
        }

        /// Sensible x-axis day stride for the window so the date labels
        /// don't collide.
        var xAxisDayStride: Int {
            switch self {
            case .oneWeek:     return 1
            case .fourWeeks:   return 7
            case .twelveWeeks: return 14
            case .all:         return 30
            }
        }

        var labelKey: String {
            switch self {
            case .oneWeek:     return "insights.window.oneWeek"
            case .fourWeeks:   return "insights.window.fourWeeks"
            case .twelveWeeks: return "insights.window.twelveWeeks"
            case .all:         return "insights.window.all"
            }
        }
    }
}
