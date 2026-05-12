import Charts
import SwiftUI

/// Shared lab-value chart used by both `LabTrendSection` (inside an entry's
/// detail view) and `LabParameterDetailView` (the new Blutwerte deep-dive).
///
/// Both call sites already have domain types (`LabTrendSection.Track`,
/// `LabSeries`) — they each adapt into the small `Point` shape here so the
/// chart stays free of either dependency.
struct LabValueChart: View {

    struct Point: Identifiable, Hashable {
        let id: UUID
        let date: Date
        let value: Double
        /// True for the point we want to emphasise. In `LabTrendSection`
        /// that's the measurement from the currently-open entry. In
        /// `LabParameterDetailView` we mark the latest measurement.
        let isHighlighted: Bool
    }

    /// Axis label (typically the canonical parameter code, e.g. "ANC").
    let parameter: String
    /// Sorted ascending by date.
    let points: [Point]
    /// Reference band drawn as a translucent rectangle behind the line.
    /// Pass `nil` to omit (matches pre-existing `LabTrendSection` behaviour).
    let referenceBand: (min: Double, max: Double)?
    /// Chart height — small in the entry-detail facets, larger in the
    /// dedicated detail screen.
    let height: CGFloat
    /// Axis stride in days. 7 for short ranges, 14/30 for longer windows.
    let xAxisDayStride: Int

    init(
        parameter: String,
        points: [Point],
        referenceBand: (min: Double, max: Double)? = nil,
        height: CGFloat = 100,
        xAxisDayStride: Int = 7
    ) {
        self.parameter = parameter
        self.points = points
        self.referenceBand = referenceBand
        self.height = height
        self.xAxisDayStride = xAxisDayStride
    }

    var body: some View {
        Chart {
            if let band = referenceBand {
                RectangleMark(
                    yStart: .value("Referenz min", band.min),
                    yEnd: .value("Referenz max", band.max)
                )
                .foregroundStyle(Color.green.opacity(0.10))
            }
            ForEach(points) { point in
                LineMark(
                    x: .value("Datum", point.date),
                    y: .value(parameter, point.value)
                )
                .foregroundStyle(.secondary)
                .interpolationMethod(.monotone)
                PointMark(
                    x: .value("Datum", point.date),
                    y: .value(parameter, point.value)
                )
                .foregroundStyle(pointColor(for: point))
                .symbolSize(point.isHighlighted ? 80 : 40)
            }
        }
        .frame(height: height)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: xAxisDayStride)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.twoDigits))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
    }

    private func pointColor(for point: Point) -> Color {
        let outOfRange: Bool = {
            guard let band = referenceBand else { return false }
            return point.value < band.min || point.value > band.max
        }()
        if outOfRange { return .orange }
        if point.isHighlighted { return Color.accentColor }
        return Color.secondary
    }
}
