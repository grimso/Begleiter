import Foundation

/// Pure-Swift step that turns a `LabPlotSpec` + the current `ChildState`
/// + the journal `[JournalEntry]` into a fully materialised
/// `LabPlotResult` the renderer can draw without any further data
/// lookups.
///
/// No MLX, no networking, no SwiftUI imports — testable with synthetic
/// fixtures. Reuses `LabSeries.aggregate(entries:)` for the
/// parameter-grouped points and `ChildState.dateRange(forPhase:…)` for
/// phase-relative windows.
nonisolated enum LabPlotResolver {

    /// Resolve a spec against the current child + journal.
    ///
    /// - Parameters:
    ///   - spec: parsed plot description (from the heuristic or Gemma path)
    ///   - child: SwiftData record; provides phase history for window
    ///     resolution
    ///   - entries: full journal — the resolver aggregates per-parameter
    ///     series internally
    ///   - now: clock injection point for tests / relative windows
    /// - Returns: `LabPlotResult` with one `LabPlotPanel` per parameter
    ///   in the spec, each carrying one `LabPlotWindowPoints` per window
    ///   (same order). Empty `points` arrays mean the cell had no
    ///   matching measurement; a `LabPlotWarning` will be set.
    static func resolve(
        spec: LabPlotSpec,
        child: ChildState,
        entries: [JournalEntry],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> LabPlotResult {
        // 1. Resolve each window to an absolute DateInterval (or nil if
        //    the window referenced an unentered phase).
        let resolvedRanges: [DateInterval?] = spec.windows.map { window in
            switch window {
            case .phase(let phaseRaw, let fromDay, let toDay, _):
                guard let phase = Phase(rawValue: phaseRaw) else { return nil }
                return child.dateRange(
                    forPhase: phase,
                    fromDay: fromDay,
                    toDay: toDay,
                    calendar: calendar
                )
            case .relativeDays(let daysBack, _):
                let end = now
                let start = calendar.date(byAdding: .day, value: -max(0, daysBack), to: end)
                    ?? end
                return DateInterval(start: start, end: end)
            case .absolute(let from, let to, _):
                return DateInterval(start: min(from, to), end: max(from, to))
            }
        }

        // 2. Build a parameter → LabSeries lookup once, so each panel
        //    can grab its source series without re-aggregating.
        let allSeries = LabSeries.aggregate(entries: entries)
        let seriesByParameter: [String: LabSeries] = Dictionary(
            uniqueKeysWithValues: allSeries.map { ($0.parameter, $0) }
        )

        // 3. For each parameter, build a panel with one points-list per
        //    window. Missing series → empty panel (renderer shows a
        //    placeholder).
        var warnings: Set<LabPlotWarning> = []
        var panels: [LabPlotPanel] = []
        for parameter in spec.parameters {
            // Canonicalize via the full synonym table so Gemma outputs
            // like "Leukozyten" / "Neutrophile" / "Platelets" map onto
            // the WBC / ANC / PLT keys produced by `LabSeries.aggregate`.
            // `LabSeries.canonicalKey` only folds the HB/HGB family.
            let canonical = LabSeries.canonicalKey(
                for: LabParameterCanonicalizer.canonical(for: parameter)
            )
            let series = seriesByParameter[canonical]
            let germanLabel = series?.germanLabel ?? canonical
            let unit = series?.unit ?? ""
            let referenceMin = series?.referenceMin
            let referenceMax = series?.referenceMax

            var windowsOut: [LabPlotWindowPoints] = []
            for (index, window) in spec.windows.enumerated() {
                let range = resolvedRanges[index]
                let label = displayLabel(for: window)

                guard let series, let range else {
                    if range == nil { warnings.insert(.phaseNotYetEntered) }
                    windowsOut.append(LabPlotWindowPoints(
                        label: label,
                        dateRange: range,
                        points: []
                    ))
                    if series != nil { warnings.insert(.noPointsInWindow) }
                    continue
                }

                // Filter ascending series points by the window. range.end
                // is exclusive (start-of-next-day), so `contains` does
                // the right thing.
                let pointsInRange = series.points.filter { point in
                    point.date >= range.start && point.date < range.end
                }
                let mapped: [LabPlotWindowPoints.Point] = pointsInRange.map { p in
                    LabPlotWindowPoints.Point(
                        id: p.id,
                        date: p.date,
                        value: p.value,
                        sourceEntryId: p.sourceEntryId
                    )
                }
                if mapped.isEmpty { warnings.insert(.noPointsInWindow) }
                windowsOut.append(LabPlotWindowPoints(
                    label: label,
                    dateRange: range,
                    points: mapped
                ))
            }

            panels.append(LabPlotPanel(
                parameter: canonical,
                germanLabel: germanLabel,
                unit: unit,
                referenceMin: referenceMin,
                referenceMax: referenceMax,
                windows: windowsOut
            ))
        }

        return LabPlotResult(
            spec: spec,
            panels: panels,
            resolvedRanges: resolvedRanges,
            warnings: Array(warnings).sorted { $0.rawValue < $1.rawValue }
        )
    }

    /// Human-readable German label for a window — uses the parser-
    /// supplied `label` when present, otherwise composes one from the
    /// window's structural fields.
    static func displayLabel(for window: LabPlotSpec.Window) -> String {
        switch window {
        case .phase(let phaseRaw, let fromDay, let toDay, let label):
            if let label, !label.isEmpty { return label }
            let phaseLabel = Phase(rawValue: phaseRaw)?.germanLabel ?? phaseRaw
            if fromDay == toDay {
                return "\(phaseLabel), Tag \(fromDay)"
            }
            return "\(phaseLabel), Tag \(min(fromDay, toDay))–\(max(fromDay, toDay))"
        case .relativeDays(let daysBack, let label):
            if let label, !label.isEmpty { return label }
            if daysBack == 7  { return "letzte Woche" }
            if daysBack == 14 { return "letzte 2 Wochen" }
            if daysBack == 30 { return "letzter Monat" }
            return "letzte \(daysBack) Tage"
        case .absolute(let from, let to, let label):
            if let label, !label.isEmpty { return label }
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.locale = Locale(identifier: "de_DE")
            return "\(formatter.string(from: from)) – \(formatter.string(from: to))"
        }
    }
}
