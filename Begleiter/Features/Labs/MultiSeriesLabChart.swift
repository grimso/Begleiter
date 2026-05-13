import Charts
import SwiftUI

/// Multi-series companion to `LabValueChart`. Used by the overlay layout
/// of `LabPlotResultView` to show two (or more) time windows for the
/// same parameter on a normalised "day-in-window" x-axis with different
/// colours per window.
///
/// Single-window callers should keep using `LabValueChart` — it's
/// optimised for the date-axis case with reference-band background.
/// This component is for **shape comparison** (does ANC drop faster in
/// the first phase vs the last?), not for absolute-date plotting.
struct MultiSeriesLabChart: View {

    struct Series: Identifiable, Hashable {
        let id = UUID()
        let label: String
        let color: Color
        let points: [Point]
    }

    struct Point: Identifiable, Hashable {
        let id = UUID()
        /// 0-indexed day offset from the start of THIS series' window.
        let dayInWindow: Int
        let value: Double
    }

    /// Axis label (typically the canonical parameter code, e.g. "ANC").
    let parameter: String
    /// Y-axis unit suffix (e.g. "G/L"). Optional — empty hides it.
    let unit: String
    /// One series per window. Same parameter, different time slices,
    /// rendered in their own colour.
    let series: [Series]
    /// Reference band drawn as a translucent rectangle behind both
    /// series. Pass `nil` to omit. Same primitive `LabValueChart` uses.
    let referenceBand: (min: Double, max: Double)?
    /// Chart height. Default matches `LabValueChart`'s detail-screen
    /// size; the composer view can shrink it for compact layouts.
    let height: CGFloat

    init(
        parameter: String,
        unit: String = "",
        series: [Series],
        referenceBand: (min: Double, max: Double)? = nil,
        height: CGFloat = 120
    ) {
        self.parameter = parameter
        self.unit = unit
        self.series = series
        self.referenceBand = referenceBand
        self.height = height
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
            ForEach(series) { s in
                ForEach(s.points) { point in
                    LineMark(
                        x: .value("Tag", point.dayInWindow),
                        y: .value(parameter, point.value)
                    )
                    .foregroundStyle(by: .value("Fenster", s.label))
                    .interpolationMethod(.monotone)
                    PointMark(
                        x: .value("Tag", point.dayInWindow),
                        y: .value(parameter, point.value)
                    )
                    .foregroundStyle(by: .value("Fenster", s.label))
                    .symbolSize(40)
                }
            }
        }
        .frame(height: height)
        .chartForegroundStyleScale(
            domain: series.map(\.label),
            range:  series.map(\.color)
        )
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                if let dayValue = value.as(Int.self) {
                    AxisValueLabel("Tag \(dayValue)")
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
    }
}
