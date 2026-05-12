import Foundation

/// One lab parameter's full history across all journal entries, plus the
/// reference range to compare the latest measurement against.
///
/// Pure value type; built by `LabSeries.aggregate(entries:)` from a
/// `[JournalEntry]` snapshot. Has no SwiftData / UI dependencies and is
/// trivially testable.
nonisolated struct LabSeries: Identifiable, Sendable, Hashable {
    /// Canonical short code, uppercased (e.g. "ANC", "PLT", "HB").
    let parameter: String
    /// German label as last reported on a measurement (e.g. "Neutrophile Granulozyten").
    let germanLabel: String
    /// Unit as last reported on a measurement (e.g. "G/L").
    let unit: String
    /// Measurements sorted ascending by date.
    let points: [LabPoint]
    /// Latest non-nil reference minimum across the series, if any.
    let referenceMin: Double?
    /// Latest non-nil reference maximum across the series, if any.
    let referenceMax: Double?

    var id: String { parameter }

    var latest: LabPoint? { points.last }

    var previous: LabPoint? {
        guard points.count >= 2 else { return nil }
        return points[points.count - 2]
    }

    /// Direction of the most recent change. `.stable` when there is no
    /// previous point or the magnitude of change is below 5%.
    var trend: TrendDirection {
        guard let latest, let previous else { return .stable }
        guard previous.value != 0 else { return .stable }
        let delta = (latest.value - previous.value) / abs(previous.value)
        if delta > 0.05 { return .up }
        if delta < -0.05 { return .down }
        return .stable
    }

    /// Percentage change from previous to latest (signed). `nil` when
    /// only one point exists or the previous value is 0.
    var percentChange: Double? {
        guard let latest, let previous else { return nil }
        guard previous.value != 0 else { return nil }
        return (latest.value - previous.value) / abs(previous.value)
    }

    /// True when the latest value falls outside the reference band, if a
    /// band is known. False when no band exists or the latest is in band.
    var isLatestOutOfRange: Bool {
        guard let latest else { return false }
        if let min = referenceMin, latest.value < min { return true }
        if let max = referenceMax, latest.value > max { return true }
        return false
    }
}

/// One measurement within a `LabSeries`. Carries the source entry's id so
/// the UI can deep-link back to the journal entry that contributed this
/// value.
nonisolated struct LabPoint: Identifiable, Sendable, Hashable {
    let id: UUID
    let date: Date
    let value: Double
    let sourceEntryId: UUID
    let source: LabValue.Source
}

nonisolated enum TrendDirection: Sendable, Hashable {
    case up, down, stable
}

extension LabSeries {

    /// Clinical priority for parameter ordering on the lab values screen.
    /// `HGB` is canonicalised to `HB` so blood-count synonyms collapse
    /// into one series.
    static let priorityOrder: [String] = ["ANC", "PLT", "HB", "WBC", "CRP", "ALT", "AST"]

    /// Aggregate one `LabSeries` per parameter from the given entries.
    ///
    /// - Filters out non-`.extracted` entries (matches the invariant used
    ///   by `BriefingService` / `HandoffService`).
    /// - Groups by canonical (uppercased) parameter; `HGB` synonyms fold
    ///   into `HB`.
    /// - Points within a series are sorted ascending by `measuredAt`.
    /// - `germanLabel`, `unit`, `referenceMin`, `referenceMax` are taken
    ///   from the most recent measurement that supplied them.
    /// - Output series are ordered by `priorityOrder` first, then
    ///   alphabetically by canonical parameter.
    static func aggregate(entries: [JournalEntry]) -> [LabSeries] {
        let extracted = entries.filter {
            if case .extracted = $0.processingStatus { return true }
            return false
        }

        var buckets: [String: [(lab: LabValue, entryId: UUID)]] = [:]
        for entry in extracted {
            let labs = entry.extractedFields.labValues?.value ?? []
            for lab in labs {
                let key = canonicalKey(for: lab.parameter)
                buckets[key, default: []].append((lab, entry.entryId))
            }
        }

        let series: [LabSeries] = buckets.map { (key, raw) -> LabSeries in
            // Sort all measurements ascending by date.
            let sorted = raw.sorted { $0.lab.measuredAt < $1.lab.measuredAt }

            let points = sorted.map { item -> LabPoint in
                LabPoint(
                    id: UUID(),
                    date: item.lab.measuredAt,
                    value: item.lab.value,
                    sourceEntryId: item.entryId,
                    source: item.lab.source
                )
            }

            // germanLabel / unit: take from the most recent measurement.
            let latest = sorted.last!.lab
            let germanLabel = latest.germanLabel.isEmpty ? key : latest.germanLabel
            let unit = latest.unit

            // referenceMin / referenceMax: take from the most recent
            // measurement that supplied them (walk descending until found).
            var referenceMin: Double?
            var referenceMax: Double?
            for item in sorted.reversed() {
                if referenceMin == nil, let min = item.lab.referenceMin {
                    referenceMin = min
                }
                if referenceMax == nil, let max = item.lab.referenceMax {
                    referenceMax = max
                }
                if referenceMin != nil && referenceMax != nil { break }
            }

            return LabSeries(
                parameter: key,
                germanLabel: germanLabel,
                unit: unit,
                points: points,
                referenceMin: referenceMin,
                referenceMax: referenceMax
            )
        }

        return series.sorted(by: priorityCompare)
    }

    /// Canonicalise a raw parameter string into the key we group by.
    ///
    /// Uppercases, trims, and folds common hemoglobin synonyms (`HGB`,
    /// `HÄMOGLOBIN`, `HEMOGLOBIN`) to `HB` so the most clinically
    /// important parameter doesn't fragment across spellings.
    static func canonicalKey(for parameter: String) -> String {
        let upper = parameter.uppercased().trimmingCharacters(in: .whitespaces)
        switch upper {
        case "HGB", "HÄMOGLOBIN", "HEMOGLOBIN", "HAEMOGLOBIN":
            return "HB"
        default:
            return upper
        }
    }

    /// Compare two series for output order: priority list first (lower
    /// `priorityOrder` index → earlier), then alphabetical by canonical
    /// parameter for the rest.
    private static func priorityCompare(_ lhs: LabSeries, _ rhs: LabSeries) -> Bool {
        let li = priorityOrder.firstIndex(of: lhs.parameter)
        let ri = priorityOrder.firstIndex(of: rhs.parameter)
        switch (li, ri) {
        case let (l?, r?):
            return l < r
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.parameter < rhs.parameter
        }
    }
}
