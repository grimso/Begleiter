import SwiftUI

/// Renders a `LabPlotResult` according to `spec.layout`:
///
/// - `.sideBySideByParameter` — one row per parameter, each row is an
///   HStack of compact `LabValueChart` cells (one cell per window) so
///   the parent can visually compare absolute date ranges.
/// - `.overlayWindowsPerParameter` — one chart per parameter using
///   `MultiSeriesLabChart`; windows overlaid on a normalised
///   "day-in-window" x-axis for shape comparison.
///
/// The view is self-contained: takes a `LabPlotResult` (already fully
/// resolved by `LabPlotResolver`), no data access of its own.
struct LabPlotResultView: View {
    let result: LabPlotResult

    /// Two-tone palette for the overlay layout. The compose view picks
    /// these; pinned here so the legend colours stay consistent
    /// regardless of which call site rendered the result.
    static let overlayColors: [Color] = [.accentColor, .orange]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(result.spec.title)
                .font(.title3.bold())
                .frame(maxWidth: .infinity, alignment: .leading)

            if !result.warnings.isEmpty {
                warningBanners
            }

            VStack(spacing: 12) {
                ForEach(result.panels) { panel in
                    panelView(panel)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Per-panel rendering

    @ViewBuilder
    private func panelView(_ panel: LabPlotPanel) -> some View {
        switch result.spec.layout {
        case .sideBySideByParameter:
            sideBySideRow(panel)
        case .overlayWindowsPerParameter:
            overlayChart(panel)
        }
    }

    /// One row: parameter header + an HStack of one chart per window.
    private func sideBySideRow(_ panel: LabPlotPanel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            parameterHeader(panel)
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(panel.windows.enumerated()), id: \.offset) { _, window in
                    sideBySideCell(panel: panel, window: window)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// One small chart cell rendered with the shared LabValueChart so it
    /// inherits the reference band + point-colour-out-of-range styling.
    private func sideBySideCell(
        panel: LabPlotPanel,
        window: LabPlotWindowPoints
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(window.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if window.points.isEmpty {
                emptyCellPlaceholder
            } else {
                LabValueChart(
                    parameter: panel.parameter,
                    points: window.points.map { p in
                        LabValueChart.Point(
                            id: p.id,
                            date: p.date,
                            value: p.value,
                            isHighlighted: false
                        )
                    },
                    referenceBand: referenceBand(panel),
                    height: 80,
                    xAxisDayStride: xAxisStride(for: window)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyCellPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.08))
            Text(L10n.t("labs.plotComposer.cell.noPoints"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(height: 80)
    }

    /// One overlay chart per parameter — both windows on a normalised
    /// "day-in-window" x-axis.
    private func overlayChart(_ panel: LabPlotPanel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            parameterHeader(panel)
            MultiSeriesLabChart(
                parameter: panel.parameter,
                unit: panel.unit,
                series: panel.windows.enumerated().map { (idx, window) in
                    let color = Self.overlayColors[idx % Self.overlayColors.count]
                    return MultiSeriesLabChart.Series(
                        label: window.label,
                        color: color,
                        points: window.points.map { p in
                            MultiSeriesLabChart.Point(
                                dayInWindow: dayOffset(of: p, in: window),
                                value: p.value
                            )
                        }
                    )
                },
                referenceBand: referenceBand(panel),
                height: 140
            )
        }
        .padding(.vertical, 4)
    }

    // MARK: - Header + helpers

    private func parameterHeader(_ panel: LabPlotPanel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(panel.germanLabel)
                .font(.subheadline.weight(.semibold))
            Text(panel.parameter)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            if !panel.unit.isEmpty {
                Text("(\(panel.unit))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func referenceBand(_ panel: LabPlotPanel) -> (min: Double, max: Double)? {
        guard let lo = panel.referenceMin, let hi = panel.referenceMax else { return nil }
        return (lo, hi)
    }

    /// Choose a sensible x-axis tick stride for the cell: 1 day if the
    /// window spans ≤ 7 days, 7 days if ≤ 35, 14 days otherwise.
    private func xAxisStride(for window: LabPlotWindowPoints) -> Int {
        guard let range = window.dateRange else { return 7 }
        let days = Calendar.current.dateComponents(
            [.day], from: range.start, to: range.end
        ).day ?? 7
        switch days {
        case ..<8:    return 1
        case ..<36:   return 7
        default:      return 14
        }
    }

    /// 0-indexed offset of a measurement from the start of its window.
    /// Used by the overlay layout so two windows of different absolute
    /// dates can share an x-axis.
    private func dayOffset(
        of point: LabPlotWindowPoints.Point,
        in window: LabPlotWindowPoints
    ) -> Int {
        guard let range = window.dateRange else { return 0 }
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: range.start),
            to: Calendar.current.startOfDay(for: point.date)
        ).day ?? 0
        return max(0, days)
    }

    // MARK: - Warnings

    private var warningBanners: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(result.warnings, id: \.self) { warning in
                Label(label(for: warning), systemImage: icon(for: warning))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func label(for warning: LabPlotWarning) -> String {
        switch warning {
        case .noPointsInWindow:
            return L10n.t("labs.plotComposer.warning.noPointsInWindow")
        case .phaseNotYetEntered:
            return L10n.t("labs.plotComposer.warning.phaseNotYetEntered")
        case .parameterShorthandUnknown:
            return L10n.t("labs.plotComposer.warning.parameterShorthandUnknown")
        }
    }

    private func icon(for warning: LabPlotWarning) -> String {
        switch warning {
        case .noPointsInWindow:           return "tray"
        case .phaseNotYetEntered:         return "calendar.badge.exclamationmark"
        case .parameterShorthandUnknown:  return "questionmark.diamond"
        }
    }
}
