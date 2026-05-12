import SwiftData
import SwiftUI

/// "Verlauf" section in `EntryDetailView` — one small chart per lab
/// parameter from the current entry, plotting that parameter's history
/// across **all** journal entries with the current entry's data point
/// highlighted.
///
/// Designed for the recall demo beat: while reading a single entry, the
/// parent should immediately see how its lab values fit the trajectory
/// (e.g. "ANC was 0.6 here — typical nadir, recovering by visit 5").
///
/// Built on Swift Charts (iOS 16+, native, no extra dependency).
struct LabTrendSection: View {
    let currentEntry: JournalEntry

    @Query(sort: \JournalEntry.visitDate, order: .forward)
    private var allEntries: [JournalEntry]

    var body: some View {
        let groups = LabTrendSection.tracksForCurrentEntry(
            currentEntry: currentEntry,
            allEntries: allEntries
        )
        if !groups.isEmpty {
            ForEach(groups) { track in
                TrackFacet(track: track)
            }
        }
    }

    // MARK: - Data shape

    struct TrackPoint: Identifiable, Hashable {
        let id: UUID                  // JournalEntry.entryId at this point
        let date: Date
        let value: Double
        let isCurrent: Bool
    }

    struct Track: Identifiable {
        let id: String                // parameter
        let parameter: String
        let germanLabel: String
        let unit: String
        let points: [TrackPoint]
        let currentValue: Double?
    }

    /// Build one `Track` per lab parameter present in `currentEntry`.
    /// Each track contains every measurement of that parameter across
    /// `allEntries`, sorted by visit date.
    ///
    /// Ordering: clinical priority list first (ANC, WBC, Hb, PLT, CRP),
    /// then alphabetical for everything else.
    static func tracksForCurrentEntry(
        currentEntry: JournalEntry,
        allEntries: [JournalEntry]
    ) -> [Track] {
        let currentLabs = currentEntry.extractedFields.labValues?.value ?? []
        guard !currentLabs.isEmpty else { return [] }

        // Build params present in the current entry, deduplicated.
        var seenParams = Set<String>()
        var orderedParams: [(parameter: String, germanLabel: String, unit: String)] = []
        for lab in currentLabs {
            let key = lab.parameter.uppercased()
            guard !seenParams.contains(key) else { continue }
            seenParams.insert(key)
            orderedParams.append((lab.parameter, lab.germanLabel, lab.unit))
        }
        orderedParams.sort { lhs, rhs in
            priorityIndex(for: lhs.parameter) < priorityIndex(for: rhs.parameter)
        }

        // For each, gather points from all entries.
        var tracks: [Track] = []
        for (parameter, germanLabel, unit) in orderedParams {
            var points: [TrackPoint] = []
            var currentValue: Double?
            for entry in allEntries {
                let labs = entry.extractedFields.labValues?.value ?? []
                for lab in labs where lab.parameter.uppercased() == parameter.uppercased() {
                    let isCurrent = entry.entryId == currentEntry.entryId
                    if isCurrent { currentValue = lab.value }
                    points.append(TrackPoint(
                        id: entry.entryId,
                        date: entry.visitDate,
                        value: lab.value,
                        isCurrent: isCurrent
                    ))
                }
            }
            // Skip trivial tracks (a single data point isn't really a
            // trend — and would render as just a dot). Show only if
            // there are at least 2 measurements.
            guard points.count >= 2 else { continue }
            tracks.append(Track(
                id: parameter,
                parameter: parameter,
                germanLabel: germanLabel,
                unit: unit,
                points: points.sorted { $0.date < $1.date },
                currentValue: currentValue
            ))
        }
        return tracks
    }

    /// Clinical priority for parameter ordering. Lower = render first.
    private static func priorityIndex(for parameter: String) -> Int {
        let upper = parameter.uppercased()
        let priority = ["ANC", "WBC", "HB", "HGB", "PLT", "CRP", "ALT", "AST"]
        if let i = priority.firstIndex(of: upper) { return i }
        return 100 + upper.hashValue % 100  // alphabetical-ish bucket for the rest
    }
}

// MARK: - One facet (header + shared chart)

private struct TrackFacet: View {
    let track: LabTrendSection.Track

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(track.germanLabel)
                    .font(.subheadline.bold())
                Spacer()
                if let current = track.currentValue {
                    Text("\(formatted(current)) \(track.unit)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }
            LabValueChart(
                parameter: track.parameter,
                points: track.points.map {
                    LabValueChart.Point(
                        id: $0.id,
                        date: $0.date,
                        value: $0.value,
                        isHighlighted: $0.isCurrent
                    )
                }
            )
        }
        .padding(.vertical, 4)
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%g", value)
    }
}
